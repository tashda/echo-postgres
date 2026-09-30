# A PostgreSQL server that only accepts encrypted connections, for TLSIntegrationTests.
# Built by start-server.sh, which creates the certificates first.
ARG POSTGRES_VERSION=17
FROM postgres:${POSTGRES_VERSION}
COPY certs/server.crt certs/server.key certs/ca.crt /etc/postgresql-tls/
RUN chown postgres:postgres /etc/postgresql-tls/* && chmod 600 /etc/postgresql-tls/server.key
COPY init-tls.sh /docker-entrypoint-initdb.d/10-tls.sh
CMD ["postgres", "-c", "ssl=on", \
     "-c", "ssl_cert_file=/etc/postgresql-tls/server.crt", \
     "-c", "ssl_key_file=/etc/postgresql-tls/server.key", \
     "-c", "ssl_ca_file=/etc/postgresql-tls/ca.crt"]
