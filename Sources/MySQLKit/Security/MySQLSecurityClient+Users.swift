import MySQLWire

public extension MySQLSecurityClient {
    func listUsers() async throws -> [MySQLUserAccount] {
        let sql = """
        SELECT
            User,
            Host,
            plugin,
            account_locked,
            password_expired
        FROM mysql.user
        ORDER BY User, Host;
        """

        let connection = try await serverConnection.metadata()
        let result = try await connection.query(sql, binds: [])
        return result.rows.compactMap { row in
            guard
                let username = row.field("User")?.string,
                let host = row.field("Host")?.string
            else {
                return nil
            }

            return MySQLUserAccount(
                username: username,
                host: host,
                authenticationPlugin: row.field("plugin")?.string,
                accountLocked: row.field("account_locked")?.string?.uppercased() == "Y",
                passwordExpired: row.field("password_expired")?.string?.uppercased() == "Y"
            )
        }
    }

    func showGrants(for username: String, host: String) async throws -> [String] {
        let escapedUser = username.replacingOccurrences(of: "'", with: "''")
        let escapedHost = host.replacingOccurrences(of: "'", with: "''")
        let sql = "SHOW GRANTS FOR '\(escapedUser)'@'\(escapedHost)'"

        let connection = try await serverConnection.metadata()
        let rows = try await connection.simpleQuery(sql)
        return rows.compactMap { row in
            row.columnDefinitions.compactMap { row.column($0.name)?.string }.first
        }
    }
}
