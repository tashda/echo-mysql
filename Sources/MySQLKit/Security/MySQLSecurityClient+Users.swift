import MySQLWire

public extension MySQLSecurityClient {
    func listUsers() async throws -> [MySQLUserAccount] {
        let sql = try await isMariaDB() ? Self.mariaDBUsersSQL : Self.mysqlUsersSQL

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

    internal static let mysqlUsersSQL = """
        SELECT User, Host, plugin, account_locked, password_expired
        FROM mysql.user
        ORDER BY User, Host;
        """

    /// MariaDB 10.4+ keeps accounts in mysql.global_priv as JSON; its mysql.user view has no
    /// account_locked column.
    internal static let mariaDBUsersSQL = """
        SELECT User, Host,
            JSON_VALUE(Priv, '$.plugin') AS plugin,
            IF(JSON_VALUE(Priv, '$.account_locked') = 'true', 'Y', 'N') AS account_locked,
            IF(JSON_VALUE(Priv, '$.password_last_changed') = '0', 'Y', 'N') AS password_expired
        FROM mysql.global_priv
        ORDER BY User, Host;
        """

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
