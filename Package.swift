// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "mysql-wire",
    platforms: [
        .macOS(.v13),
        .iOS(.v16)
    ],
    products: [
        .library(name: "MySQLWire", targets: ["MySQLWire"]),
        .library(name: "MySQLKit", targets: ["MySQLKit"]),
        .library(name: "MySQLKitTesting", targets: ["MySQLKitTesting"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/mysql-nio.git", from: "1.9.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "MySQLWire",
            dependencies: [
                .product(name: "MySQLNIO", package: "mysql-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "MySQLKit",
            dependencies: [
                "MySQLWire",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "MySQLKitTesting",
            dependencies: [
                "MySQLKit",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "MySQLWireTests",
            dependencies: ["MySQLWire"],
            path: "Tests/MySQLWireTests"
        ),
        .testTarget(
            name: "MySQLKitTests",
            dependencies: ["MySQLKit", "MySQLKitTesting"],
            path: "Tests/MySQLKitTests"
        ),
        // Against a real server (Tests/with-lab.sh, or MYSQL_* in CI); skipped without one.
        .testTarget(
            name: "MySQLIntegrationTests",
            dependencies: ["MySQLKit", "MySQLKitTesting"],
            path: "Tests/MySQLIntegrationTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
