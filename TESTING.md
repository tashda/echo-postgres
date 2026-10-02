# Testing echo-postgres

The unit tests need nothing. The integration tests need a PostgreSQL server, which they find
through **one URL variable per setup**. A test whose variable is not set is skipped, and the skip
says which variable to set. Plain Docker is enough for every setup except Kerberos.

```bash
swift test                    # unit tests; every server test is skipped
```

## A plain server

```bash
docker run -d --name postgres-test -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:17
POSTGRES_TEST_URL='postgres://postgres:postgres@localhost:5432/postgres?sslmode=disable' swift test
docker rm -f postgres-test
```

The XCTest suites load their sample data (`Tests/PostgresKitTests/Support/SampleData.sql`) into a
database of their own, `postgres_wire_test_<random>`, and drop it, and the roles it creates, when the
run ends. Tests that create server-wide objects (roles, tablespaces) remove them afterwards too, so
the server is left as it was. Versions 14 to 18 are supported.

## The variables

| Variable | Server | Tests |
|---|---|---|
| `POSTGRES_TEST_URL` | a plain server | almost all integration tests |
| `POSTGRES_TEST_TLS_URL` | a server that requires TLS; the URL carries `sslmode` and the CA | `TLSTests` |
| `POSTGRES_TEST_STANDBY_URL` | the standby of a pair whose primary is `POSTGRES_TEST_URL` | `StandbyTests`, `PhysicalReplicationTests` |
| `POSTGRES_TEST_PROXY_URL`, `POSTGRES_TEST_PROXY_CONTROL` | the `POSTGRES_TEST_URL` server through a [Toxiproxy](https://github.com/Shopify/toxiproxy), and the proxy's HTTP API | `ProxyFailoverTests` |
| `POSTGRES_TEST_KERBEROS_URL` | Kerberos (GSSAPI) logins | `KerberosTests` |
| `POSTGRES_TEST_REQUIRED=1` | a missing variable fails the test instead of skipping it (CI sets it) | all |

URLs are libpq's, with the user and password percent-encoded:

```
postgres://postgres:pass@localhost:5432/postgres?sslmode=disable
postgres://postgres:pass@host:5432/postgres?sslmode=verify-full&sslrootcert=/ca.pem&sslcert=/c.pem&sslkey=/k.pem
postgres://alice%40LAB.TEST@host:5432/postgres?sslmode=disable&authentication=kerberos&serviceHost=pg.lab.test&krb5Config=/krb5.conf
```

The path names the database to connect to. Other libpq keys are read too: `sslpassword`,
`connect_timeout`, `application_name`, `krbsrvname`, `target_session_attrs`, `load_balance_hosts`.
Tests in other packages can use the same parser and trait from `PostgresKitTesting`:
`TestServer.url("POSTGRES_TEST_URL")` and `@Suite(.testServer)` / `@Suite(.testServer("POSTGRES_TEST_TLS_URL"))`,
which provide `TestServer.current`.

## TLS

A server with a certificate from a CA of its own, accepting only TLS connections:

```bash
mkdir -p /tmp/pg-tls && cd /tmp/pg-tls
openssl req -x509 -new -nodes -newkey rsa:2048 -days 30 -subj "/CN=echo-postgres test CA" -keyout ca.key -out ca.crt
openssl req -new -nodes -newkey rsa:2048 -subj "/CN=localhost" -keyout server.key -out server.csr
printf 'subjectAltName=DNS:localhost\n' > server.ext
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -extfile server.ext -out server.crt
printf 'local all all trust\nhostssl all all all scram-sha-256\n' > pg_hba.conf
docker run -d --name postgres-tls -e POSTGRES_PASSWORD=postgres -p 5433:5432 -v "$PWD":/certs:ro postgres:17 bash -c \
  'install -o postgres -m 600 /certs/server.key /tmp/server.key && install -o postgres -m 644 /certs/server.crt /tmp/server.crt &&
   exec docker-entrypoint.sh postgres -c ssl=on -c ssl_cert_file=/tmp/server.crt -c ssl_key_file=/tmp/server.key -c hba_file=/certs/pg_hba.conf'
cd - && POSTGRES_TEST_TLS_URL='postgres://postgres:postgres@localhost:5433/postgres?sslmode=verify-full&sslrootcert=/tmp/pg-tls/ca.crt' swift test --filter TLSTests
docker rm -f postgres-tls
```

With `sslcert` and `sslkey` in the URL, `TLSTests` also checks that the server sees the client
certificate. Key files (encrypted keys, `.p12`/`.pfx`) are tested without a server:
`ClientCertificateFileTests`.

## A primary and a standby

```bash
docker network create pg-pair
docker run -d --name pg-primary --network pg-pair -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:17
until docker exec pg-primary pg_isready -U postgres -h 127.0.0.1; do sleep 1; done
docker exec pg-primary bash -c 'echo "host replication all all scram-sha-256" >> "$PGDATA/pg_hba.conf"'
docker exec pg-primary psql -U postgres -c 'SELECT pg_reload_conf()'
docker run --rm --network pg-pair -v pg-standby:/var/lib/postgresql/data -e PGPASSWORD=postgres postgres:17 bash -c \
  'pg_basebackup -h pg-primary -U postgres -D /var/lib/postgresql/data -R -X stream &&
   chown -R postgres:postgres /var/lib/postgresql/data && chmod 700 /var/lib/postgresql/data'
docker run -d --name pg-standby --network pg-pair -v pg-standby:/var/lib/postgresql/data -p 5434:5432 postgres:17
until docker exec pg-primary psql -U postgres -Atc 'SELECT count(*) FROM pg_stat_replication' | grep -q 1; do sleep 1; done
POSTGRES_TEST_URL='postgres://postgres:postgres@localhost:5432/postgres?sslmode=disable' \
POSTGRES_TEST_STANDBY_URL='postgres://postgres:postgres@localhost:5434/postgres?sslmode=disable' \
  swift test --filter 'StandbyTests|PhysicalReplicationTests'
docker rm -f pg-primary pg-standby && docker volume rm pg-standby && docker network rm pg-pair
```

## A server that goes away (failover)

`ProxyFailoverTests` switch a Toxiproxy off and on through its API to make the server unreachable,
with the server itself (`POSTGRES_TEST_URL`) as the host to fail over to:

```bash
docker network create pg-proxy
docker run -d --name pg-server --network pg-proxy -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:17
docker run -d --name pg-toxiproxy --network pg-proxy -p 8474:8474 -p 6432:6432 ghcr.io/shopify/toxiproxy
until curl -s localhost:8474/version; do sleep 1; done
curl -s -X POST localhost:8474/proxies -d '{"name":"postgres","listen":"0.0.0.0:6432","upstream":"pg-server:5432"}'
POSTGRES_TEST_URL='postgres://postgres:postgres@localhost:5432/postgres?sslmode=disable' \
POSTGRES_TEST_PROXY_URL='postgres://postgres:postgres@localhost:6432/postgres?sslmode=disable' \
POSTGRES_TEST_PROXY_CONTROL='http://localhost:8474' \
  swift test --filter ProxyFailoverTests
docker rm -f pg-server pg-toxiproxy && docker network rm pg-proxy
```

## Kerberos (optional)

`KerberosTests` need a KDC and a server set up for GSSAPI, so they are skipped unless
`POSTGRES_TEST_KERBEROS_URL` is set. The URL's user is the principal (`alice@LAB.TEST`); the database
user is its name without the realm (`include_realm=0`). `serviceHost` is the host name in the
server's principal when it differs from the URL's host, and `krb5Config` the realm's Kerberos
settings file. The tests use your ticket for that principal (`kinit` first); with a password in the
URL they get a ticket of their own instead. Without either they are skipped.

On Linux, building needs MIT Kerberos (`libkrb5-dev`).

## CI

`.github/workflows/test.yml` runs the unit tests on every push, the integration tests against a
`postgres` service container for each of 14 to 18, and the TLS, standby and proxy setups above, each
with its URL variables and `POSTGRES_TEST_REQUIRED=1`.
