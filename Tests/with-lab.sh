#!/usr/bin/env bash
# Runs a command against a fresh PostgreSQL server from echo-server-lab (on testlab) and removes
# the server afterwards, also when the command fails or is interrupted. This is how the tests use a
# database server; nothing stays running.
#
#   Tests/with-lab.sh swift test --filter PostgresKitTests
#   SERVERLAB_RECIPE=pg-14-empty Tests/with-lab.sh swift test
#
# The suite loads SampleData.sql into the server itself (PostgresLabFixture). The lab checkout is
# ../echo-server-lab (or SERVERLAB_PACKAGE); its password comes from ~/.echo-testlab/credentials.env.
set -euo pipefail
recipe="${SERVERLAB_RECIPE:-pg-17-empty}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
lab="${SERVERLAB_PACKAGE:-$repo/../echo-server-lab}"
cli="${SERVERLAB_CLI:-$lab/.build/release/serverlab}"
if [ ! -x "$cli" ]; then
  swift build -c release --product serverlab --package-path "$lab" >&2
fi
# The repo's .env may point at a real server; the lab server's variables win (TestEnv skips
# POSTGRES_* from .env while SERVERLAB_CONTAINER is set).
eval "$("$cli" up "$recipe" --env --owner postgres-wire --lease "${SERVERLAB_LEASE:-90}")"
trap '"$cli" down "$SERVERLAB_CONTAINER" >&2 || true' EXIT
echo "Lab server $SERVERLAB_CONTAINER ($recipe) at $POSTGRES_HOST:$POSTGRES_PORT" >&2
unset USE_DOCKER
"$@"
