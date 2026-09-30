#!/bin/bash
# Starts two PostgreSQL servers for FailoverIntegrationTests, which stop, start and switch them
# to read-only (as a failover does). Prints the environment for the tests:
#
#   eval "$(Tests/Fixtures/failover/start-servers.sh)"; swift test --filter FailoverIntegrationTests
#
# POSTGRES_VERSION (default 17), POSTGRES_FAILOVER_PORT_A (54351) and _B (54352).
set -euo pipefail
version="${POSTGRES_VERSION:-17}"
port_a="${POSTGRES_FAILOVER_PORT_A:-54351}"
port_b="${POSTGRES_FAILOVER_PORT_B:-54352}"
for pair in "a:$port_a" "b:$port_b"; do
  name="postgres-wire-failover-${pair%%:*}"
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" -e POSTGRES_PASSWORD=postgres -p "${pair##*:}:5432" "postgres:$version" >/dev/null
done
for name in postgres-wire-failover-a postgres-wire-failover-b; do
  for _ in $(seq 1 60); do
    if docker exec "$name" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; then break; fi
    sleep 1
  done
done
sleep 1
echo "export POSTGRES_FAILOVER_PORT_A=$port_a"
echo "export POSTGRES_FAILOVER_PORT_B=$port_b"
echo "export POSTGRES_FAILOVER_CONTAINER_A=postgres-wire-failover-a"
echo "export POSTGRES_FAILOVER_CONTAINER_B=postgres-wire-failover-b"
