#!/bin/bash
# Roles for the Kerberos users; only Kerberos over TCP (postgres keeps a password for setup).
# bob has a principal but no role, to check the server's refusal.
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -c "CREATE ROLE alice LOGIN"
cat > "$PGDATA/pg_hba.conf" <<'HBA'
local   all  all                trust
host    all  postgres  all      scram-sha-256
host    all  all       all      gss include_realm=0 krb_realm=EXAMPLE.TEST
HBA
