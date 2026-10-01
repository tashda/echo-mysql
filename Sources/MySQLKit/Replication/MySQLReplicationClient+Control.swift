import MySQLWire

/// The replica's view of replication, from `SHOW REPLICA STATUS` (MySQL and MariaDB names).
public struct MySQLReplicaState: Sendable, Hashable {
    public let sourceHost: String?
    public let ioRunning: Bool
    public let sqlRunning: Bool
    public let secondsBehindSource: Int?
    public let lastError: String?

    init(_ values: [String: String?]) {
        func value(_ names: String...) -> String? { names.lazy.compactMap { values[$0] ?? nil }.first }
        sourceHost = value("Source_Host", "Master_Host")
        ioRunning = value("Replica_IO_Running", "Slave_IO_Running") == "Yes"
        sqlRunning = value("Replica_SQL_Running", "Slave_SQL_Running") == "Yes"
        secondsBehindSource = value("Seconds_Behind_Source", "Seconds_Behind_Master").flatMap(Int.init)
        let error = [value("Last_IO_Error"), value("Last_SQL_Error")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "; ")
        lastError = error.isEmpty ? nil : error
    }
}

public extension MySQLReplicationClient {
    /// Points this server at a source with GTID auto-positioning (MySQL `CHANGE REPLICATION SOURCE TO`,
    /// MariaDB `CHANGE MASTER TO … MASTER_USE_GTID = slave_pos`). `getSourcePublicKey` lets a
    /// `caching_sha2_password` account authenticate without TLS (MySQL only).
    func configureSource(host: String, port: Int = 3306, user: String, password: String,
                         useTLS: Bool = false, getSourcePublicKey: Bool = true) async throws {
        let flavor = try await serverFlavor()
        try await execute(Self.configureSourceSQL(flavor: flavor, host: host, port: port, user: user, password: password,
                                                  useTLS: useTLS, getSourcePublicKey: getSourcePublicKey))
    }

    func startReplica() async throws {
        try await execute(try await serverFlavor().usesReplicaKeywords ? "START REPLICA" : "START SLAVE")
    }

    func stopReplica() async throws {
        try await execute(try await serverFlavor().usesReplicaKeywords ? "STOP REPLICA" : "STOP SLAVE")
    }

    /// Forgets the source (`RESET REPLICA ALL` / `RESET SLAVE ALL`), e.g. after promoting this server.
    func resetReplica() async throws {
        try await execute(try await serverFlavor().usesReplicaKeywords ? "RESET REPLICA ALL" : "RESET SLAVE ALL")
    }

    /// `read_only` (and on MySQL `super_read_only`, which also stops administrators from writing).
    func setReadOnly(_ readOnly: Bool) async throws {
        let flavor = try await serverFlavor()
        if flavor.isMariaDB || readOnly {
            try await execute("SET GLOBAL read_only = \(readOnly ? "ON" : "OFF")")
        }
        if !flavor.isMariaDB { try await execute("SET GLOBAL super_read_only = \(readOnly ? "ON" : "OFF")") }
    }

    func replicaState() async throws -> MySQLReplicaState? {
        try await replicaStatus().map { MySQLReplicaState($0.rawValues) }
    }

    /// MySQL or MariaDB, and the version, which decide the replication keywords.
    struct ServerFlavor: Sendable, Hashable {
        public let isMariaDB: Bool
        public let major: Int
        public let minor: Int
        public let patch: Int

        /// MySQL 8.0.23+ says SOURCE/REPLICA everywhere; MariaDB and older MySQL say MASTER/SLAVE.
        var usesReplicaKeywords: Bool { !isMariaDB && (major, minor, patch) >= (8, 0, 23) }

        init(version: String) {
            isMariaDB = version.localizedCaseInsensitiveContains("mariadb")
            let numbers = version.split(whereSeparator: { !$0.isNumber && $0 != "." }).first.map {
                $0.split(separator: ".").compactMap { Int($0) }
            } ?? []
            major = numbers.first ?? 0
            minor = numbers.count > 1 ? numbers[1] : 0
            patch = numbers.count > 2 ? numbers[2] : 0
        }
    }

    func serverFlavor() async throws -> ServerFlavor {
        let connection = try await serverConnection.primary()
        let rows = try await connection.simpleQuery("SELECT VERSION() AS version")
        return ServerFlavor(version: rows.first?.field("version")?.string ?? "")
    }

    internal static func configureSourceSQL(flavor: ServerFlavor, host: String, port: Int, user: String, password: String,
                                            useTLS: Bool, getSourcePublicKey: Bool) -> String {
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'" }
        if flavor.isMariaDB {
            return "CHANGE MASTER TO MASTER_HOST = \(quoted(host)), MASTER_PORT = \(port), MASTER_USER = \(quoted(user)), "
                + "MASTER_PASSWORD = \(quoted(password)), MASTER_SSL = \(useTLS ? 1 : 0), MASTER_USE_GTID = slave_pos"
        }
        if flavor.usesReplicaKeywords {
            return "CHANGE REPLICATION SOURCE TO SOURCE_HOST = \(quoted(host)), SOURCE_PORT = \(port), SOURCE_USER = \(quoted(user)), "
                + "SOURCE_PASSWORD = \(quoted(password)), SOURCE_SSL = \(useTLS ? 1 : 0), SOURCE_AUTO_POSITION = 1"
                + (getSourcePublicKey ? ", GET_SOURCE_PUBLIC_KEY = 1" : "")
        }
        return "CHANGE MASTER TO MASTER_HOST = \(quoted(host)), MASTER_PORT = \(port), MASTER_USER = \(quoted(user)), "
            + "MASTER_PASSWORD = \(quoted(password)), MASTER_SSL = \(useTLS ? 1 : 0), MASTER_AUTO_POSITION = 1"
            + (getSourcePublicKey ? ", GET_MASTER_PUBLIC_KEY = 1" : "")
    }

    private func execute(_ sql: String) async throws {
        let connection = try await serverConnection.primary()
        _ = try await connection.simpleQuery(sql)
    }
}
