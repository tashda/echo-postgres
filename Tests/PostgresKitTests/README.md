# PostgresKit tests

How to run them, and which server each needs: [TESTING.md](../../TESTING.md).

- XCTest suites subclass `PostgresKitTestCase`: they need `POSTGRES_TEST_URL` and run on the run's
  own sample database (`Support/SampleDatabase.swift`, data in `Support/SampleData.sql`), dropped
  when the run ends.
- Swift Testing suites use `@Suite(.testServer)` or `@Suite(.testServer("POSTGRES_TEST_TLS_URL"))`
  from `PostgresKitTesting` and read `TestServer.current`.
- Tests create what they need through the driver and remove it afterwards: objects in the sample
  database go with it; server-wide objects (roles, tablespaces) are dropped in `addTeardownBlock`,
  which runs before `tearDown` closes the client.
- No Docker, psql or `.env` from test code.
