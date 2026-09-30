# PostgreSQL that signs users in with Kerberos (GSSAPI), with its own KDC for the realm
# EXAMPLE.TEST, for KerberosIntegrationTests. Started by start-server.sh.
ARG POSTGRES_VERSION=17
FROM postgres:${POSTGRES_VERSION}
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends krb5-kdc krb5-admin-server && rm -rf /var/lib/apt/lists/*
COPY krb5.conf /etc/krb5.conf
COPY kdc.conf /etc/krb5kdc/kdc.conf
COPY entrypoint-kerberos.sh /usr/local/bin/entrypoint-kerberos.sh
COPY init-kerberos.sh /docker-entrypoint-initdb.d/10-kerberos.sh
ENTRYPOINT ["/usr/local/bin/entrypoint-kerberos.sh"]
CMD ["postgres", "-c", "krb_server_keyfile=/etc/postgresql-krb/postgres.keytab"]
