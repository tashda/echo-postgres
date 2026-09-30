# PostgresWire & PostgresKit

A high-performance, SwiftNIO-based PostgreSQL client library for Swift, providing both low-level wire protocol access and high-level ergonomic APIs for application development.

## Overview

- **PostgresWire**: A thin, focused wrapper over Vapor's `PostgresNIO`, exposing a minimal interface for connections, queries, and streaming. It is designed to be easily testable and extremely fast.
- **PostgresKit**: Built on top of `PostgresWire`, this module provides a higher-level client with connection abstractions, statement caching, metadata utilities, and ergonomic APIs suitable for modern Swift applications.

## Features

- **High Performance**: Built directly on `SwiftNIO` and `PostgresNIO`.
- **Async/Await**: Modern Swift concurrency support throughout the API.
- **Statement Caching**: Simple LRU cache for prepared statements to optimize repeated queries.
- **Execution Options**: Fine-grained control over query execution, including server-side cursor thresholds and fetch baselines.
- **Metadata Utilities**: Helpers to list databases, schemas, tables, and object definitions natively in Swift.
- **Independent**: Clean API surface completely independent of any specific web framework.
- **Failover**: with several hosts (libpq's multi-host strings, `targetSessionAttributes`), the pool
  moves to another server when its own can't be reached (after `connectTimeout`, not PostgresNIO's
  60 s) or, for read-write and primary, turns read-only after a failover. A call is retried only when
  nothing could have run twice.
- **Sign-in**: passwords (SCRAM-SHA-256, MD5), TLS in every libpq `sslmode` with client certificates
  (and encrypted keys, `sslKeyPassword`), AWS RDS IAM tokens, and **Kerberos** (GSSAPI, and SSPI from
  Windows servers) with the user's existing ticket (`kerberosServiceName`, `postgres` by default).

## Prerequisites

- **Swift 6.0+**
- **PostgreSQL 14, 15, 16, 17, 18** (Required for integration testing)
- **Docker** (Optional, for automated testing)
- **Linux only:** MIT Kerberos headers (`apt install libkrb5-dev`, `dnf install krb5-devel`) for
  Kerberos sign-in. macOS uses the built-in GSS framework.

## Installation

Add `postgres-wire` to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/tashda/postgres-wire.git", from: "1.0.0")
]
```

Add the products you need to your targets:

```swift
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "PostgresKit", package: "postgres-wire")
            // Or just PostgresWire if you only need the low-level client
        ]
    )
]
```

## Usage

### High-Level API (PostgresKit)

PostgresKit provides an ergonomic interface for querying your database with modern concurrency:

```swift
import PostgresKit

// 1. Configure the connection
let config = PostgresConfiguration(
    host: "localhost",
    port: 5432,
    database: "my_db",
    username: "postgres",
    password: "password",
    useTLS: false
)

// 2. Connect
let client = try await PostgresClient.connect(configuration: config)
defer { client.close() }

// 3. Query
let rows = try await client.simpleQuery("SELECT id, name FROM users WHERE active = true")
for try await row in rows {
    print("User: \(row)")
}
```

### Low-Level API (PostgresWire)

PostgresWire is available if you need granular control over the execution protocol:

```swift
import PostgresWire

let options = PostgresExecutionOptions(
    mode: .auto,               // or .simple, .cursor
    cursorThreshold: 25_000,   // LIMIT ≤ 25k → use simple
    fetchBaseline: 4_096,      // baseline cursor fetch
    fetchRampMultiplier: 24,
    fetchRampMax: 524_288,
    progressThrottleMs: 120
)

let client = try await PostgresWireClient.connect(configuration: config)
let rows = try await client.query(
    WireQuery(sql: "SELECT * FROM public.fixture LIMIT 10000;"),
    options: options
)
```

## Integration Testing

Locally, the integration tests run against a disposable PostgreSQL server from
[echo-server-lab](https://github.com/tashda/echo-server-lab), which is removed when the run ends:

```bash
Tests/with-lab.sh swift test --filter 'PostgresKitTests|PostgresWireTests'
```

The suite loads `Tests/PostgresKitTests/Support/SampleData.sql` into the server itself
(`PostgresLabFixture`). The TLS, Kerberos and failover tests need their own servers on Docker; this
starts them and removes them afterwards:

```bash
Tests/Fixtures/with-fixtures.sh tls kerberos failover -- \
  swift test --filter 'TLSIntegrationTests|KerberosIntegrationTests|FailoverIntegrationTests'
```

The Docker setup below is what CI uses.

## Integration Testing with Docker

This project includes a lightweight, built-in utility to run integration tests against a live PostgreSQL database managed by Docker.

### Automated Multi-Version Testing

A convenient shell script is provided to test against multiple PostgreSQL versions (14, 15, 16, 17, 18, and `latest`):

```bash
./test-all-postgres-versions.sh
```

### Manual Docker Integration

Alternatively, you can run tests against a single Docker instance by setting environment variables:

```bash
export USE_DOCKER=1
export POSTGRES_VERSION=16
swift test --filter PostgresKitTests
```

When `USE_DOCKER=1` is set:
1.  The test suite automatically spins up a Docker PostgreSQL container.
2.  Loads a sample database from `Tests/PostgresKitTests/Support/SampleData.sql`.
3.  Overrides connection details to point to the temporary Docker container.
4.  Stops and removes the container after the tests complete.

### TLS and Kerberos servers

Three more fixtures start servers the default one can't cover; their tests are skipped without them:

```bash
eval "$(Tests/Fixtures/tls/start-server.sh)"        # TLS only: private CA, server and client certificates
swift test --filter TLSIntegrationTests

eval "$(Tests/Fixtures/kerberos/start-server.sh)"   # Kerberos only, with its own KDC (realm EXAMPLE.TEST)
swift test --filter KerberosIntegrationTests

eval "$(Tests/Fixtures/failover/start-servers.sh)"  # two servers the tests stop, start and make read-only
swift test --filter FailoverIntegrationTests
```

The Kerberos fixture keeps its own `krb5.conf` and ticket cache in `Tests/Fixtures/kerberos/state`;
your own Kerberos setup and tickets are not used or changed.

## Documentation

Comprehensive documentation can be generated using Swift-DocC:

```bash
swift package generate-documentation
```

## License

This project is licensed under the Apache 2.0 License. See the [LICENSE.txt](LICENSE.txt) file for details.

It includes a copy of [PostgresNIO](https://github.com/vapor/postgres-nio) (MIT License) in
`Sources/PostgresNIO` and `Sources/_ConnectionPoolModule`; its licence, notice and the list of changes
are in [ThirdParty/postgres-nio](ThirdParty/postgres-nio).
