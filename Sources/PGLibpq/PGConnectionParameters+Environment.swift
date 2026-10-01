extension PGConnectionParameters {
    /// A path that never exists (`/var/empty` is empty and root-owned on macOS and Linux).
    static let missingFile = "/var/empty/echo-no-file"

    /// The keywords libpq would otherwise take from the environment, with explicit values.
    ///
    /// libpq fills every keyword a connection doesn't give from its `PG*` environment variable,
    /// and an empty value doesn't stop that; it also reads `~/.pgpass`, `~/.postgresql/root.crt`,
    /// `postgresql.crt`/`.key` and `root.crl` when their keywords are unset. A user's shell must not
    /// change how Echo connects, so every such keyword gets a value here: the caller's, or libpq's
    /// own default, or (for files) a path that never exists, which libpq treats as "no file".
    ///
    /// Not closable this way (libpq has no neutral non-empty value for them): `service`
    /// (`PGSERVICE`), `hostaddr`, `password`, `require_auth`, `requirepeer`. libpq also sends
    /// `PGDATESTYLE`, `PGTZ` and `PGGEQO` as startup settings, which the server applies after
    /// `options`: `PGConnection` checks the reported `DateStyle` after connecting and sets the
    /// output format back to ISO when needed (`requireISODates`). The date *order* (DMY/MDY, for
    /// parsing what users type) and the time zone stay as the server or those variables say; Echo
    /// keeps the server's order on purpose (a European server set to DMY stays DMY).
    func closedToTheEnvironment() -> PGConnectionParameters {
        var closed = self
        let defaults: KeyValuePairs<String, String> = [
            "sslmode": "prefer",
            "sslnegotiation": "postgres",
            "sslcompression": "0",
            "sslcertmode": "allow",
            "sslsni": "1",
            "sslrootcert": Self.missingFile,
            "sslcert": Self.missingFile,
            "sslkey": Self.missingFile,
            "sslcrl": Self.missingFile,
            "sslcrldir": Self.missingFile,
            "passfile": Self.missingFile,
            "ssl_min_protocol_version": "TLSv1.2",
            "ssl_max_protocol_version": "TLSv1.3",
            "min_protocol_version": "3.0",
            "max_protocol_version": "3.0",
            "channel_binding": "prefer",
            "client_encoding": "UTF8",
            "application_name": "PGLibpq",
            "options": "-c DateStyle=ISO -c IntervalStyle=postgres",
            // Kerberos encryption only when asked for (decision D7): probing GSS is slow without a
            // KDC and breaks forked children (pg_dump -j).
            "gssencmode": "disable",
            "krbsrvname": "postgres",
            "gsslib": "gssapi",
            "gssdelegation": "0",
            "target_session_attrs": "any",
            "load_balance_hosts": "disable",
        ]
        for (keyword, value) in defaults where closed[keyword] == nil {
            closed.set(keyword, value)
        }
        return closed
    }
}
