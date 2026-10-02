import Foundation
import MDBConnector
import Testing

/// The lab server from `MYSQL_TEST_URL` (`serverlab run --recipe mysql-8.4-empty -- swift test`).
enum LabServer {
    static let url = ProcessInfo.processInfo.environment["MYSQL_TEST_URL"].flatMap(URLComponents.init(string:))
    static var isAvailable: Bool { url != nil }

    static var options: MDBConnectOptions {
        guard let url else { return MDBConnectOptions(host: "localhost", user: "root") }
        let database = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var options = MDBConnectOptions(
            host: url.host ?? "localhost", port: url.port ?? 3306,
            user: url.user?.removingPercentEncoding ?? "root",
            password: url.password?.removingPercentEncoding,
            database: database.isEmpty ? nil : database,
            connectTimeoutSeconds: 15, tls: .disabled
        )
        if url.queryItems?.contains(where: { $0.name == "ssl-mode" && $0.value?.uppercased() == "REQUIRED" }) == true {
            options.tls = .required
        }
        return options
    }

    static func connect() async throws -> MDBConnection {
        try await MDBConnection.connect(options)
    }

    /// A connection in a scratch database of this run (created once; the lab removes the server).
    static func connectWithDatabase() async throws -> MDBConnection {
        let connection = try await connect()
        _ = try await connection.execute("CREATE DATABASE IF NOT EXISTS mdb_tests; USE mdb_tests")
        return connection
    }
}

extension Trait where Self == ConditionTrait {
    static var labServer: Self { .enabled(if: LabServer.isAvailable, "Needs MYSQL_TEST_URL (serverlab run)") }
}

extension MDBEvent {
    var rows: [MDBRow]? { if case .rows(let rows) = self { rows } else { nil } }
    var done: MDBCommandResult? { if case .done(let result) = self { result } else { nil } }
    var columns: [MDBField]? { if case .columns(let fields) = self { fields } else { nil } }
}
