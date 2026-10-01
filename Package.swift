// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "mysql-wire",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .library(name: "MySQLKit", targets: ["MySQLKit"]),
        .library(name: "MySQLKitTesting", targets: ["MySQLKitTesting"]),
    ],
    dependencies: [
        // MariaDB Connector/C (macOS: the universal framework built by echo-libraries; Linux: the
        // system's libmariadb), and on macOS the Keychain trust and client certificates (EchoTLS).
        .package(url: "https://github.com/tashda/echo-libraries", from: "1.1.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        // The system's MariaDB Connector/C on Linux (libmariadb-dev).
        .systemLibrary(
            name: "CMariaDBSystem",
            pkgConfig: "libmariadb",
            providers: [.apt(["libmariadb-dev"]), .yum(["mariadb-connector-c-devel"])]
        ),
        // The transport: the only code that calls Connector/C. Each connection is an actor on its
        // own serial queue, woken by socket readiness (no thread ever blocks).
        .target(
            name: "MDBConnector",
            dependencies: [
                .product(name: "CMariaDB", package: "echo-libraries", condition: .when(platforms: [.macOS])),
                .target(name: "CMariaDBSystem", condition: .when(platforms: [.linux])),
            ]
        ),
        .target(
            name: "MySQLKit",
            dependencies: [
                "MDBConnector",
                .product(name: "EchoTLS", package: "echo-libraries", condition: .when(platforms: [.macOS])),
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
            name: "MDBConnectorTests",
            dependencies: ["MDBConnector"]
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
