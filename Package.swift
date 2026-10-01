// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "postgres-wire",
    platforms: [ .macOS(.v26) ],
    products: [
        .library(name: "PostgresKit", targets: ["PostgresKit"]),
        .library(name: "PostgresKitTesting", targets: ["PostgresKitTesting"])
    ],
    dependencies: [
        // libpq (macOS: universal frameworks built by echo-libraries; Linux: the system's libpq),
        // and on macOS the Keychain trust, client certificates and Kerberos ticket (EchoTLS, EchoKerberos).
        .package(url: "https://github.com/tashda/echo-libraries", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.9.0" ..< "5.0.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.5"),
    ],
    targets: [
        // The system's libpq on Linux (libpq-dev, PostgreSQL 17+ for chunked rows).
        .systemLibrary(
            name: "CLibpqSystem",
            pkgConfig: "libpq",
            providers: [.apt(["libpq-dev"]), .yum(["libpq-devel"])]
        ),
        // The libpq transport: the only code that calls libpq. Each connection is an actor running
        // on its own serial queue, woken by socket readiness (no thread ever blocks).
        .target(
            name: "PGLibpq",
            dependencies: [
                .product(name: "CLibpq", package: "echo-libraries", condition: .when(platforms: [.macOS])),
                .target(name: "CLibpqSystem", condition: .when(platforms: [.linux])),
            ]
        ),
        .target(
            name: "PostgresKit",
            dependencies: [
                "PGLibpq",
                .product(name: "EchoTLS", package: "echo-libraries", condition: .when(platforms: [.macOS])),
                .product(name: "EchoKerberos", package: "echo-libraries", condition: .when(platforms: [.macOS])),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "PostgresKitTesting",
            dependencies: ["PostgresKit"]
        ),
        .testTarget(
            name: "PGLibpqTests",
            dependencies: ["PGLibpq"]
        ),
        .testTarget(
            name: "PostgresKitTests",
            dependencies: [
                "PostgresKit",
                "PostgresKitTesting",
            ],
            path: "Tests/PostgresKitTests",
            exclude: ["README.md", "Support/SampleData.sql", "Support/certificates"]
        )
    ]
)
