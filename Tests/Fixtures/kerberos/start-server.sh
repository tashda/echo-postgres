#!/bin/bash
# Starts PostgreSQL with Kerberos sign-in and its own KDC (realm EXAMPLE.TEST), gets alice a
# ticket in a private cache (your own Kerberos setup and tickets are not used or changed), and
# prints the environment for KerberosIntegrationTests:
#
#   eval "$(Tests/Fixtures/kerberos/start-server.sh)"; swift test --filter KerberosIntegrationTests
#
# POSTGRES_VERSION (default 17), POSTGRES_KRB_TEST_PORT (54340) and POSTGRES_KRB_KDC_PORT (18088).
set -euo pipefail
fixture="$(cd "$(dirname "$0")" && pwd)"
state="$fixture/state"
port="${POSTGRES_KRB_TEST_PORT:-54340}"
kdc_port="${POSTGRES_KRB_KDC_PORT:-18088}"
version="${POSTGRES_VERSION:-17}"
name="postgres-wire-kerberos-$version"
rm -rf "$state"; mkdir -p "$state"
docker rm -f "$name" >/dev/null 2>&1 || true
docker build -q --build-arg POSTGRES_VERSION="$version" -t "$name" "$fixture" >/dev/null
docker run -d --rm --name "$name" -e POSTGRES_PASSWORD=postgres \
  -p "$port:5432" -p "$kdc_port:88/tcp" -p "$kdc_port:88/udp" "$name" >/dev/null
for _ in $(seq 1 90); do
  if docker exec "$name" pg_isready -U postgres -h 127.0.0.1 >/dev/null 2>&1; then break; fi
  sleep 1
done
sleep 1
cat > "$state/krb5.conf" <<CONF
[libdefaults]
    default_realm = EXAMPLE.TEST
    dns_lookup_realm = false
    dns_lookup_kdc = false
    rdns = false
    dns_canonicalize_hostname = false
    udp_preference_limit = 1
[realms]
    EXAMPLE.TEST = {
        kdc = 127.0.0.1:$kdc_port
    }
[domain_realm]
    localhost = EXAMPLE.TEST
CONF
export KRB5_CONFIG="$state/krb5.conf"
export KRB5CCNAME="FILE:$state/ccache"
if kinit --version 2>&1 | grep -qi heimdal; then
  echo "alice-password" | kinit --password-file=STDIN alice@EXAMPLE.TEST >/dev/null
else
  echo "alice-password" | kinit alice@EXAMPLE.TEST >/dev/null
fi
echo "export POSTGRES_KRB_TEST_PORT=$port"
echo "export KRB5_CONFIG=$KRB5_CONFIG"
echo "export KRB5CCNAME=$KRB5CCNAME"
echo "export POSTGRES_KRB_TEST_CONTAINER=$name"
