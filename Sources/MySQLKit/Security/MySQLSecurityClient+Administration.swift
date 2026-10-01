import Foundation
import MySQLWire

public extension MySQLSecurityClient {
    func accountLimits(for username: String, host: String) async throws -> MySQLAccountLimits? {
        let sql = """
        SELECT
            max_questions,
            max_updates,
            max_connections,
            max_user_connections
        FROM mysql.user
        WHERE User = ? AND Host = ?
        LIMIT 1;
        """

        let connection = try await serverConnection.metadata()
        let result = try await connection.query(
            sql,
            binds: [MySQLData(string: username), MySQLData(string: host)]
        )
        guard let row = result.rows.first else {
            return nil
        }

        return MySQLAccountLimits(
            maxQueriesPerHour: row.field("max_questions")?.string.flatMap(Int.init) ?? 0,
            maxUpdatesPerHour: row.field("max_updates")?.string.flatMap(Int.init) ?? 0,
            maxConnectionsPerHour: row.field("max_connections")?.string.flatMap(Int.init) ?? 0,
            maxUserConnections: row.field("max_user_connections")?.string.flatMap(Int.init) ?? 0
        )
    }

    func setAccountLimits(
        for username: String,
        host: String,
        limits: MySQLAccountLimits
    ) async throws -> MySQLUserMutationResult {
        let statement = """
        ALTER USER '\(escapedLiteral(username))'@'\(escapedLiteral(host))' WITH \
        MAX_QUERIES_PER_HOUR \(limits.maxQueriesPerHour) \
        MAX_UPDATES_PER_HOUR \(limits.maxUpdatesPerHour) \
        MAX_CONNECTIONS_PER_HOUR \(limits.maxConnectionsPerHour) \
        MAX_USER_CONNECTIONS \(limits.maxUserConnections)
        """
        try await executeSecurityStatement(statement)
        return MySQLUserMutationResult(username: username, host: host, operation: "ALTER USER LIMITS")
    }

    func administrativeRoles(for username: String, host: String) async throws -> [MySQLAdministrativeRole] {
        let grants = try await showGrants(for: username, host: host)
        let normalizedGrantText = grants.joined(separator: "\n").uppercased()

        return MySQLAdministrativeRole.allCases.filter { role in
            requiredPrivileges(for: role).allSatisfy { normalizedGrantText.contains($0) }
        }
    }

    func grantAdministrativeRole(
        _ role: MySQLAdministrativeRole,
        to username: String,
        host: String
    ) async throws {
        let privileges = requiredPrivileges(for: role).joined(separator: ", ")
        try await grant(privileges, on: "*.*", to: username, host: host)
    }

    func revokeAdministrativeRole(
        _ role: MySQLAdministrativeRole,
        from username: String,
        host: String
    ) async throws {
        let privileges = requiredPrivileges(for: role).joined(separator: ", ")
        try await revoke(privileges, on: "*.*", from: username, host: host)
    }

    private func requiredPrivileges(for role: MySQLAdministrativeRole) -> [String] {
        switch role {
        case .dba:
            return ["ALL PRIVILEGES"]
        case .maintenanceAdmin:
            return ["RELOAD", "LOCK TABLES", "EVENT"]
        case .processAdmin:
            return ["PROCESS"]
        case .userAdmin:
            return ["CREATE USER"]
        case .securityAdmin:
            return ["CREATE USER", "GRANT OPTION"]
        case .monitorAdmin:
            return ["PROCESS", "REPLICATION CLIENT"]
        case .dbManager:
            return ["CREATE", "ALTER", "DROP"]
        case .dbDesigner:
            return ["CREATE", "ALTER", "INDEX", "REFERENCES"]
        case .replicationAdmin:
            return ["REPLICATION SLAVE", "REPLICATION CLIENT"]
        case .backupAdmin:
            return ["SELECT", "SHOW VIEW", "TRIGGER", "LOCK TABLES"]
        }
    }
}
