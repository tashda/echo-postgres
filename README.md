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

## Testing

The unit tests need nothing: `swift test`. The integration tests need a PostgreSQL server, which
they find through a URL variable, and are skipped without it:

```bash
docker run -d --name postgres-test -e POSTGRES_PASSWORD=postgres -p 5432:5432 postgres:17
POSTGRES_TEST_URL='postgres://postgres:postgres@localhost:5432/postgres?sslmode=disable' swift test
```

[TESTING.md](TESTING.md) lists every variable (TLS, a standby, failover through a proxy, Kerberos)
with the `docker run` lines for each setup.

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
