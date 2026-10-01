# mysql-wire

A Swift package providing a typed MySQL client for macOS and iOS applications. Built on top of [mysql-nio](https://github.com/vapor/mysql-nio), it offers a high-level, namespaced API for MySQL database operations.

## Modules

- **MySQLWire** — Low-level connection management and query execution, wrapping mysql-nio.
- **MySQLKit** — High-level typed client with namespaced APIs for metadata, admin, security, replication, performance, and session management.
- **MySQLKitTesting** — Test-server URL parsing and the `.testServer` Swift Testing trait (see TESTING.md).

## Requirements

- Swift 6.2+
- macOS 13+ / iOS 16+

## Usage

Add the package dependency:

```swift
.package(url: "https://github.com/tashda/mysql-wire.git", branch: "dev")
```

Then import `MySQLKit` (it re-exports `MySQLWire`):

```swift
import MySQLKit

let client = MySQLClient(configuration: MySQLConfiguration(
    host: "localhost",
    port: 3306,
    username: "root",
    password: "password",
    database: "mydb",
    tlsMode: .verifyIdentity()
))

// Typed metadata API
let tables = try await client.metadata.listTables(in: "mydb")

// Statements with parameters go through the binary protocol
let rows = try await client.query("SELECT * FROM users WHERE id = ?", binds: [MySQLData(int: 42)]).rows

await client.close()
```

TLS modes follow MySQL's `--ssl-mode`: `.disabled`, `.preferred` (TLS when the server offers it),
`.required`, `.verifyCA(caCertificatePath:)` and `.verifyIdentity(caCertificatePath:)`. A server that
offers no TLS is still connected to unencrypted in every mode (see TESTING.md, known issues).

## Testing

```bash
docker run -d --name mysql-test -e MYSQL_ROOT_PASSWORD=Test-Password1 -p 3306:3306 mysql:8.4
MYSQL_TEST_URL='mysql://root:Test-Password1@127.0.0.1:3306/' swift test
```

Without `MYSQL_TEST_URL` only the unit tests run. [TESTING.md](TESTING.md) lists every variable
(TLS, replication, network faults), the URL form, and how to get each server with plain Docker.

## License

Private — all rights reserved.
