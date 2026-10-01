public extension MySQLSecurityClient {
    func createUser(
        username: String,
        host: String,
        password: String? = nil,
        authenticationPlugin: String? = nil
    ) async throws -> MySQLUserMutationResult {
        try await executeSecurityStatement(createUserSQL(username: username, host: host, password: password,
                                                        authenticationPlugin: authenticationPlugin))
        return MySQLUserMutationResult(username: username, host: host, operation: "CREATE USER")
    }

    /// `IDENTIFIED BY` needs `IDENTIFIED` also without a plugin; it was left out, so a user with a
    /// password and no plugin could not be created.
    internal func createUserSQL(username: String, host: String, password: String?, authenticationPlugin: String?) -> String {
        var statement = "CREATE USER '\(escapedLiteral(username))'@'\(escapedLiteral(host))'"
        let plugin = authenticationPlugin.flatMap { $0.isEmpty ? nil : $0 }
        switch (plugin, password) {
        case let (plugin?, password?): statement += " IDENTIFIED WITH \(plugin) BY '\(escapedLiteral(password))'"
        case let (plugin?, nil): statement += " IDENTIFIED WITH \(plugin)"
        case let (nil, password?): statement += " IDENTIFIED BY '\(escapedLiteral(password))'"
        case (nil, nil): break
        }
        return statement
    }

    func dropUser(username: String, host: String, ifExists: Bool = true) async throws -> MySQLUserMutationResult {
        let existsClause = ifExists ? "IF EXISTS " : ""
        try await executeSecurityStatement(
            "DROP USER \(existsClause)'\(escapedLiteral(username))'@'\(escapedLiteral(host))'"
        )
        return MySQLUserMutationResult(username: username, host: host, operation: "DROP USER")
    }

    func alterUserPassword(username: String, host: String, password: String) async throws -> MySQLUserMutationResult {
        try await executeSecurityStatement(
            "ALTER USER '\(escapedLiteral(username))'@'\(escapedLiteral(host))' IDENTIFIED BY '\(escapedLiteral(password))'"
        )
        return MySQLUserMutationResult(username: username, host: host, operation: "ALTER USER PASSWORD")
    }

    func lockUser(username: String, host: String) async throws -> MySQLUserMutationResult {
        try await executeSecurityStatement(
            "ALTER USER '\(escapedLiteral(username))'@'\(escapedLiteral(host))' ACCOUNT LOCK"
        )
        return MySQLUserMutationResult(username: username, host: host, operation: "LOCK USER")
    }

    func unlockUser(username: String, host: String) async throws -> MySQLUserMutationResult {
        try await executeSecurityStatement(
            "ALTER USER '\(escapedLiteral(username))'@'\(escapedLiteral(host))' ACCOUNT UNLOCK"
        )
        return MySQLUserMutationResult(username: username, host: host, operation: "UNLOCK USER")
    }

    /// Grants to a user (`'name'@'host'`) or, with no host, to a role (MariaDB roles have no host).
    func grant(
        _ privilege: String,
        on object: String,
        to username: String,
        host: String?,
        withGrantOption: Bool = false
    ) async throws {
        let grantOptionClause = withGrantOption ? " WITH GRANT OPTION" : ""
        try await executeSecurityStatement(
            "GRANT \(privilege) ON \(object) TO \(roleName(username, host: host))\(grantOptionClause)"
        )
    }

    func revoke(
        _ privilege: String,
        on object: String,
        from username: String,
        host: String?
    ) async throws {
        try await executeSecurityStatement(
            "REVOKE \(privilege) ON \(object) FROM \(roleName(username, host: host))"
        )
    }

    /// Creates a role. Without a host it works on MySQL (`'name'@'%'`) and MariaDB (whose roles have no host).
    func createRole(name: String, host: String? = nil) async throws {
        try await executeSecurityStatement("CREATE ROLE \(roleName(name, host: host))")
    }

    func dropRole(name: String, host: String? = nil) async throws {
        try await executeSecurityStatement("DROP ROLE \(roleName(name, host: host))")
    }

    internal func roleName(_ name: String, host: String?) -> String {
        "'\(escapedLiteral(name))'" + (host.map { "@'\(escapedLiteral($0))'" } ?? "")
    }

    func grantRole(
        _ roleName: String,
        roleHost: String? = nil,
        to username: String,
        host: String
    ) async throws {
        try await executeSecurityStatement(
            "GRANT \(self.roleName(roleName, host: roleHost)) TO '\(escapedLiteral(username))'@'\(escapedLiteral(host))'"
        )
    }

    func revokeRole(
        _ roleName: String,
        roleHost: String? = nil,
        from username: String,
        host: String
    ) async throws {
        try await executeSecurityStatement(
            "REVOKE \(self.roleName(roleName, host: roleHost)) FROM '\(escapedLiteral(username))'@'\(escapedLiteral(host))'"
        )
    }

    func setDefaultRole(
        _ roleName: String,
        roleHost: String = "%",
        for username: String,
        host: String
    ) async throws {
        try await executeSecurityStatement(
            "SET DEFAULT ROLE '\(escapedLiteral(roleName))'@'\(escapedLiteral(roleHost))' TO '\(escapedLiteral(username))'@'\(escapedLiteral(host))'"
        )
    }

    func executeSecurityStatement(_ sql: String) async throws {
        let connection = try await serverConnection.primary()
        _ = try await connection.simpleQuery(sql)
    }

    func escapedLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
