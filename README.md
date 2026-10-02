# echo-mysql

A typed MySQL and MariaDB client for Swift on **MariaDB Connector/C**. Echo uses it for every MySQL
and MariaDB connection.

## Modules

- **MDBConnector**: the transport, and the only code that calls Connector/C. Each connection is an
  actor on its own serial queue, driving Connector/C's non-blocking API (`*_start`/`*_cont`) and woken
  by socket readiness, so no thread ever blocks while the server works.
- **MySQLKit**: the client Echo calls, with namespaced APIs for metadata, admin, security, replication,
  performance and sessions; streaming results (`events`, pulled from the server as read); cancel
  (`KILL QUERY`) and Force Stop; imports through `LOAD DATA LOCAL` (`importRows`); the TLS options for
  `mysqldump`/`mysql` (`toolTLS`).
- **MySQLKitTesting**: test-server URL parsing and the `.testServer` Swift Testing trait (TESTING.md).

Connector/C comes from [echo-libraries](https://github.com/tashda/echo-libraries) on macOS (a universal
framework with OpenSSL; every sign-in plugin built in, none loaded from disk) and from the system on
Linux (`libmariadb-dev`). It is LGPL-2.1, linked dynamically and unmodified.

## Requirements

- Swift 6.2, macOS 26.
- Linux: `libmariadb-dev` and `pkg-config`.

## Usage

```swift
.package(url: "https://github.com/tashda/echo-mysql.git", branch: "dev")
```

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

let tables = try await client.metadata.listTables(in: "mydb")

// Parameters are escaped by the connection (its character set and NO_BACKSLASH_ESCAPES); results
// always come as the server's text.
let rows = try await client.query("SELECT * FROM users WHERE id = ?", binds: [MySQLData(int: 42)]).rows

await client.close()
```

TLS modes follow MySQL's `--ssl-mode`: `.disabled`, `.preferred` (TLS when the server offers it),
`.required` (refuses a server without TLS), `.verifyCA(caCertificatePath:)` and
`.verifyIdentity(caCertificatePath:)` (the Mac's trusted CAs when no CA is given). Connector/C checks
chain and host name together, so Verify CA behaves as Verify Identity (decision D19).

## Testing

```bash
swift run --package-path ../echo-server-lab serverlab run --recipe mysql-8.4-empty -- swift test --no-parallel
```

Without `MYSQL_TEST_URL` only the unit tests run. [TESTING.md](TESTING.md) lists every variable
(TLS, replication, network faults), the URL form, and how to get each server with plain Docker.

## License

Private — all rights reserved. MariaDB Connector/C is under the LGPL-2.1.
