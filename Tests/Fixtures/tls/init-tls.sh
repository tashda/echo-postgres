#!/bin/bash
# Only encrypted connections; cert_user signs in with its client certificate.
set -e
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" -c "CREATE ROLE cert_user LOGIN"
cat > "$PGDATA/pg_hba.conf" <<'HBA'
local   all        all                 trust
hostnossl all      all        all      reject
hostssl all        cert_user  all      cert
hostssl all        all        all      scram-sha-256
HBA
