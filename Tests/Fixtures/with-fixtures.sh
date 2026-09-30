#!/usr/bin/env bash
# Starts the transport and security fixtures on this Mac's Docker, runs a command, and removes the
# containers and their images afterwards, also when the command fails or is interrupted. (These
# servers need things echo-server-lab doesn't offer: a TLS-only server with a private CA, a KDC, two
# servers the tests stop and demote. Everything else runs on a lab server: Tests/with-lab.sh.)
#
#   Tests/Fixtures/with-fixtures.sh tls kerberos failover -- \
#     swift test --filter 'TLSIntegrationTests|KerberosIntegrationTests|FailoverIntegrationTests'
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
version="${POSTGRES_VERSION:-17}"
fixtures=()
while [ $# -gt 0 ] && [ "$1" != "--" ]; do fixtures+=("$1"); shift; done
[ "${1:-}" = "--" ] && shift
[ ${#fixtures[@]} -gt 0 ] && [ $# -gt 0 ] || { echo "usage: $0 tls|kerberos|failover ... -- command" >&2; exit 2; }

cleanup() {
  for fixture in "${fixtures[@]}"; do
    case "$fixture" in
      tls) docker rm -f "postgres-wire-tls-$version" >/dev/null 2>&1 || true
           docker rmi "postgres-wire-tls-$version" >/dev/null 2>&1 || true ;;
      kerberos) docker rm -f "postgres-wire-kerberos-$version" >/dev/null 2>&1 || true
                docker rmi "postgres-wire-kerberos-$version" >/dev/null 2>&1 || true ;;
      failover) docker rm -f postgres-wire-failover-a postgres-wire-failover-b >/dev/null 2>&1 || true ;;
    esac
  done
  echo "Removed the fixtures: ${fixtures[*]}" >&2
}
trap cleanup EXIT

for fixture in "${fixtures[@]}"; do
  case "$fixture" in
    tls) eval "$("$here/tls/start-server.sh")" ;;
    kerberos) eval "$("$here/kerberos/start-server.sh")" ;;
    failover) eval "$("$here/failover/start-servers.sh")" ;;
    *) echo "unknown fixture: $fixture" >&2; exit 2 ;;
  esac
done
"$@"
