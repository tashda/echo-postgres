#!/bin/bash
# Starts a PostgreSQL server that only accepts TLS, with a private CA, a server certificate for
# "localhost" (not 127.0.0.1) and client certificates for cert_user (one key protected by a
# passphrase). Prints the environment for TLSIntegrationTests:
#
#   eval "$(Tests/Fixtures/tls/start-server.sh)"; swift test --filter TLSIntegrationTests
#
# POSTGRES_VERSION (default 17) and POSTGRES_TLS_TEST_PORT (default 54330) can be set.
set -euo pipefail
fixture="$(cd "$(dirname "$0")" && pwd)"
certs="$fixture/certs"
port="${POSTGRES_TLS_TEST_PORT:-54330}"
version="${POSTGRES_VERSION:-17}"
name="postgres-wire-tls-$version"
rm -rf "$certs"; mkdir -p "$certs"
cd "$certs"
{
  openssl req -x509 -new -nodes -newkey rsa:2048 -days 30 -subj "/CN=postgres-wire test CA" -keyout ca.key -out ca.crt
  openssl req -new -nodes -newkey rsa:2048 -subj "/CN=localhost" -keyout server.key -out server.csr
  printf "subjectAltName=DNS:localhost\n" > server.ext
  openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -extfile server.ext -out server.crt
  openssl req -new -nodes -newkey rsa:2048 -subj "/CN=cert_user" -keyout client.key -out client.csr
  openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -out client.crt
  openssl pkcs8 -topk8 -in client.key -out client-encrypted.key -passout pass:correct-horse -v2 aes-256-cbc
  # A second CA that signed nothing on the server: verify-ca with it must fail.
  openssl req -x509 -new -nodes -newkey rsa:2048 -days 30 -subj "/CN=unrelated CA" -keyout other-ca.key -out other-ca.crt
} >/dev/null 2>&1
chmod 600 ./*.key
docker rm -f "$name" >/dev/null 2>&1 || true
docker build -q --build-arg POSTGRES_VERSION="$version" -t "$name" "$fixture" >/dev/null
docker run -d --rm --name "$name" -e POSTGRES_PASSWORD=postgres -p "$port:5432" "$name" >/dev/null
for _ in $(seq 1 60); do
  if docker exec "$name" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; then break; fi
  sleep 1
done
sleep 1
echo "export POSTGRES_TLS_TEST_PORT=$port"
echo "export POSTGRES_TLS_TEST_CERTS=$certs"
echo "export POSTGRES_TLS_TEST_CONTAINER=$name"
