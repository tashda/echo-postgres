// swift-tools-version: 6.2
import PackageDescription

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
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.32.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", "3.9.0" ..< "5.0.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-metrics.git", from: "2.3.0"),
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.5")
    ],
    targets: [
        .target(
            name: "PostgresWire",
            dependencies: [
                .product(name: "PostgresNIO", package: "postgres-nio"),
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
                .product(name: "PostgresNIO", package: "postgres-nio")
            ],
            path: "Tests/PostgresWireTests"
        ),
        .testTarget(
            name: "PostgresKitTests",
            dependencies: [
                "PostgresKit",
                "PostgresKitTesting",
                .product(name: "PostgresNIO", package: "postgres-nio")
            ],
            path: "Tests/PostgresKitTests",
            exclude: ["README.md", "Support/SampleData.sql", "Support/PostgresDockerManager.swift"]
        )
    ]
)
