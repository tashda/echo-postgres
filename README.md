# PostgresKit

A PostgreSQL client library for Swift on **libpq**, PostgreSQL's own client library. Echo uses it
for every PostgreSQL connection.

## Overview

- **PGLibpq**: the transport, and the only code that calls libpq. Each connection is an actor on its
  own serial queue, driving libpq's non-blocking API and woken by socket readiness, so no thread ever
  blocks while the server works. Rows arrive in chunks (`PQsetChunkedRowsMode`, libpq 17+).
- **PostgresKit**: the client Echo calls: a small pool, query tab sessions, streaming rows, scripts,
  COPY, cancel, LISTEN/NOTIFY, notices, metadata, administration and security APIs, failover, and the
  connection the bundled tools use (`PostgresToolConnection`).

libpq comes from [echo-libraries](https://github.com/tashda/echo-libraries) on macOS (a universal
framework with OpenSSL and the PostgreSQL tools) and from the system on Linux.

## Features

- **Streaming in bounded memory**: rows are read as they are asked for; a slow reader slows the server.
- **Values as the server writes them**: every value is the server's own text (ISO dates, the server's
  `money` and interval formats), so what Echo shows is what `psql` shows.
- **Cancel and Force Stop**: cancel through libpq's cancel API; a connection can be closed while a
  statement runs.
- **Failover**: several hosts with `targetSessionAttributes` and `loadBalanceHosts` (libpq's own
  multi-host connect); the pool moves on when its server goes away.
- **Sign-in and TLS**: SCRAM-SHA-256, MD5, every `sslmode`, client certificates (PEM, DER, PKCS#8,
  encrypted keys, `.p12`), the Mac's trusted CAs for verify-ca/verify-full, and **Kerberos** (GSSAPI)
  with the user's ticket.
- **Closed to the environment**: `PG*` variables, `~/.pgpass` and `~/.postgresql` never change how a
  connection is made.

## Requirements

- Swift 6.2, macOS 26.
- Linux: libpq 17 or newer with its headers (`libpq-dev` from the PGDG repository on Ubuntu 24.04,
  which ships 16).

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/tashda/postgres-wire.git", branch: "dev")
]
```

```swift
.target(name: "YourApp", dependencies: [.product(name: "PostgresKit", package: "postgres-wire")])
```

## Usage

```swift
import PostgresKit

var configuration = PostgresConfiguration(
    host: "localhost", port: 5432, database: "my_db", username: "postgres", password: "password"
)
configuration.sslMode = .verifyFull

let client = try await PostgresClient.connect(configuration: configuration)
defer { client.close() }

for try await row in try await client.simpleQuery("SELECT id, name FROM users WHERE active") {
    let (id, name) = try row.decode((Int, String).self)
    print(id, name)
}
```

## Testing

The unit tests need nothing: `swift test`. The integration tests find their server through URL
variables (`POSTGRES_TEST_URL`, `POSTGRES_TEST_TLS_URL`, …) and are skipped without them. With
[echo-server-lab](https://github.com/tashda/echo-server-lab):

```bash
swift run --package-path ../echo-server-lab serverlab run --recipe pg-17-empty -- swift test
```

[TESTING.md](TESTING.md) lists every variable (TLS, a standby, failover through a proxy, Kerberos)
with a `docker run` line for each setup.

## License

Apache 2.0; see [LICENSE.txt](LICENSE.txt). libpq is under the PostgreSQL Licence.
