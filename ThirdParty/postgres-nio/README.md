# PostgresNIO (copied into postgres-wire)

`Sources/PostgresNIO` and `Sources/_ConnectionPoolModule` are a copy of
[vapor/postgres-nio](https://github.com/vapor/postgres-nio) 1.32.0
(commit `ea1b42104a24cee93c9a9b2b2b8498598b3cfd81`), MIT licensed (see `LICENSE`
and `NOTICE.txt` here). The documentation catalog and the tests were left out.

It was copied so postgres-wire can add what PostgresNIO does not support yet, without a fork.
Every change to the copy is listed below; keep the list current so the copy can be updated from
upstream (or the changes offered upstream) later.

## Changes

Kerberos sign-in (GSSAPI, and SSPI from Windows servers). PostgresNIO refused both; the copy
relays the tokens to an authenticator that postgres-wire supplies (`PostgresKerberos` in
PostgresWire: Apple's GSS framework on macOS, MIT Kerberos on Linux).

- `Connection/PostgresGSSAuthenticator.swift` (new): the `PostgresGSSAuthenticator` protocol and
  `PostgresGSSAuthenticatorFactory`.
- `Connection/PostgresConnection+Configuration.swift` and `Pool/PostgresClient.swift`: the options
  gain `gssAuthenticatorFactory` (default `nil`, which refuses Kerberos as before);
  `Pool/ConnectionFactory.swift` passes it from the pool to each connection.
- `New/Connection State Machine/ConnectionStateMachine.swift`: `AuthContext` carries the factory
  (not part of equality); the new `sendGSSResponse` action is sent as the existing 'p' message.
- `New/PostgresChannelHandler.swift`: builds `AuthContext` with the factory.
- `New/Connection State Machine/AuthenticationStateMachine.swift`: on `gss`/`sspi` the state
  machine asks the authenticator for the first token (state `gssTokenSent`), answers each
  `gssContinue` with the next token, and finishes on `ok`. Without a factory it refuses as before.
- `New/PSQLError+Kerberos.swift` (new): `PSQLError.serverRequestedKerberos`, so the message can say
  that the server asks for Kerberos.

Failover: the pool's circuit breaker time is configurable.

- `Pool/PostgresClient.swift`: `Options.circuitBreakerTripAfter` (default 60 s as before), passed to
  the connection pool. postgres-wire sets it to the connect timeout, so a server that can't be
  reached fails over after seconds instead of a minute.

No empty passwords: a server asking for a cleartext password when none was configured.

- `New/Connection State Machine/AuthenticationStateMachine.swift`: `plaintext` without a password
  fails with `authMechanismRequiresPassword`, as `md5` and SCRAM already did (libpq: "no password
  supplied"), instead of sending an empty password. A Kerberos-only sign-in can then say that the
  server asks for a password.

Prepared statements from `PostgresDatabase.prepare(query:)` decode non-text columns.

- `New/Connection State Machine/ExtendedQueryStateMachine.swift`: `.prepareStatement` hands back the
  row description with binary formats (the unnamed path already did), because executing the
  statement binds with binary result formats. Upstream's older `prepare(query:)` / `PreparedQuery`
  path kept the text formats from Describe, so booleans and integers failed to decode; the newer
  `PostgresPreparedStatement` path converts in `PreparedStatementStateMachine` and is unaffected.
  postgres-wire's `queryPreparedRows` uses the older path. Worth offering upstream.

`PostgresClient.isRunning`.

- `Pool/PostgresClient.swift`: a public `isRunning` (reads `runningAtomic`), so postgres-wire, which
  runs each pool in a detached task, can wait for `run()` to start before the first lease instead
  of triggering the "run() hasn't been called yet" warning.

