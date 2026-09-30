#!/bin/bash
# As root: create the realm, the service principal postgres/localhost with its keytab, and the
# user principals, start the KDC, then hand over to the normal PostgreSQL entrypoint.
set -e
if [ ! -f /var/lib/krb5kdc/principal ]; then
  kdb5_util create -s -r EXAMPLE.TEST -P master-password >/dev/null
  kadmin.local -q "addprinc -randkey postgres/localhost@EXAMPLE.TEST" >/dev/null
  kadmin.local -q "addprinc -pw alice-password alice@EXAMPLE.TEST" >/dev/null
  kadmin.local -q "addprinc -pw bob-password bob@EXAMPLE.TEST" >/dev/null
  mkdir -p /etc/postgresql-krb
  kadmin.local -q "ktadd -k /etc/postgresql-krb/postgres.keytab postgres/localhost@EXAMPLE.TEST" >/dev/null
  chown -R postgres:postgres /etc/postgresql-krb
  chmod 600 /etc/postgresql-krb/postgres.keytab
fi
krb5kdc
exec docker-entrypoint.sh "$@"
