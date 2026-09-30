// swift-tools-version: 6.2
import PackageDescription

/// PostgresNIO's own settings, for the copy in Sources/PostgresNIO.
let vendoredSwiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "postgres-wire",
    platforms: [ .macOS(.v13) ],
    products: [
        .library(name: "PostgresWire", targets: ["PostgresWire"]),
        .library(name: "PostgresKit", targets: ["PostgresKit"]),
        .library(name: "PostgresKitTesting", targets: ["PostgresKitTesting"]),
        .executable(name: "postgres-test-fixture", targets: ["PostgresFixtureTool"])
    ],
    dependencies: [
        // PostgresNIO 1.32.0 is copied into Sources/PostgresNIO (see ThirdParty/postgres-nio);
        // these are its dependencies.
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0"),
        .package(url: "https://github.com/apple/swift-collections.git", from: "1.0.4"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.19.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.25.0"),
        .package(url: "https://github.com/swift-server/swift-service-lifecycle.git", from: "2.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.9.0" ..< "5.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.3.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.5")
    ],
    targets: [
        // The copy of PostgresNIO (ThirdParty/postgres-nio/README.md lists what changed).
        .target(
            name: "PostgresNIO",
            dependencies: [
                "_ConnectionPoolModule",
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics"),
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOFoundationCompat", package: "swift-nio"),
                .product(name: "ServiceLifecycle", package: "swift-service-lifecycle"),
            ],
            swiftSettings: vendoredSwiftSettings
        ),
        .target(
            name: "_ConnectionPoolModule",
            dependencies: [
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "DequeModule", package: "swift-collections"),
            ],
            swiftSettings: vendoredSwiftSettings
        ),
        // MIT Kerberos for Kerberos sign-in on Linux; macOS uses the GSS framework.
        .systemLibrary(
            name: "CGSSAPI",
            pkgConfig: "krb5-gssapi",
            providers: [.apt(["libkrb5-dev"]), .yum(["krb5-devel"])]
        ),
        .target(
            name: "PostgresWire",
            dependencies: [
                "PostgresNIO",
                .target(name: "CGSSAPI", condition: .when(platforms: [.linux])),
                .product(name: "Logging", package: "swift-log")
            ]
        ),
        .target(
            name: "PostgresKit",
            dependencies: [
                "PostgresWire",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Metrics", package: "swift-metrics")
            ]
        ),
        .target(
            name: "PostgresKitTesting",
            dependencies: ["PostgresKit"]
        ),
        .executableTarget(
            name: "PostgresFixtureTool",
            dependencies: ["PostgresKitTesting"],
            path: "Sources/PostgresFixtureTool"
        ),
        .testTarget(
            name: "PostgresWireTests",
            dependencies: [
                "PostgresWire",
                "PostgresNIO"
            ],
            path: "Tests/PostgresWireTests"
        ),
        .testTarget(
            name: "PostgresKitTests",
            dependencies: [
                "PostgresKit",
                "PostgresKitTesting",
                "PostgresNIO"
            ],
            path: "Tests/PostgresKitTests",
            exclude: ["README.md", "Support/SampleData.sql", "Support/PostgresDockerManager.swift"]
        )
    ]
)
