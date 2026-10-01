/// What TLS an account must log in with (`REQUIRE …`).
public enum MySQLTLSRequirement: Sendable, Hashable {
    case none
    /// Any encrypted connection (`REQUIRE SSL`).
    case ssl
    /// A client certificate signed by a CA the server trusts (`REQUIRE X509`).
    case x509
    /// A client certificate with this subject, e.g. `/CN=lab_cert_user` (`REQUIRE SUBJECT`).
    case subject(String)
    /// A client certificate issued by this issuer (`REQUIRE ISSUER`).
    case issuer(String)

    var clause: String {
        func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
        switch self {
        case .none: return ""
        case .ssl: return " REQUIRE SSL"
        case .x509: return " REQUIRE X509"
        case .subject(let subject): return " REQUIRE SUBJECT \(quoted(subject))"
        case .issuer(let issuer): return " REQUIRE ISSUER \(quoted(issuer))"
        }
    }
}

public extension MySQLSecurityClient {
    func createUser(
        username: String,
        host: String,
        password: String? = nil,
        authenticationPlugin: String? = nil,
        tls: MySQLTLSRequirement = .none
    ) async throws -> MySQLUserMutationResult {
        // MariaDB words a plugin with a password differently, so only then ask which server this is.
        let mariaDB = authenticationPlugin?.isEmpty == false && password != nil ? try await isMariaDB() : false
        try await executeSecurityStatement(createUserSQL(username: username, host: host, password: password,
                                                        authenticationPlugin: authenticationPlugin, mariaDB: mariaDB) + tls.clause)
        return MySQLUserMutationResult(username: username, host: host, operation: "CREATE USER")
    }

    /// `IDENTIFIED BY` needs `IDENTIFIED` also without a plugin; it was left out, so a user with a
    /// password and no plugin could not be created. MariaDB takes a plugin's password as
    /// `IDENTIFIED VIA plugin USING PASSWORD('…')` (`ed25519`, `parsec`, `mysql_native_password`).
    internal func createUserSQL(username: String, host: String, password: String?, authenticationPlugin: String?,
                                mariaDB: Bool = false) -> String {
        var statement = "CREATE USER '\(escapedLiteral(username))'@'\(escapedLiteral(host))'"
        let plugin = authenticationPlugin.flatMap { $0.isEmpty ? nil : $0 }
        switch (plugin, password) {
        case let (plugin?, password?) where mariaDB:
            statement += " IDENTIFIED VIA \(plugin) USING PASSWORD('\(escapedLiteral(password))')"
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

    /// Changes what TLS an account must log in with (`ALTER USER … REQUIRE …`).
    @discardableResult
    func alterUserTLS(username: String, host: String, tls: MySQLTLSRequirement) async throws -> MySQLUserMutationResult {
        let clause = tls == .none ? " REQUIRE NONE" : tls.clause
        try await executeSecurityStatement("ALTER USER '\(escapedLiteral(username))'@'\(escapedLiteral(host))'\(clause)")
        return MySQLUserMutationResult(username: username, host: host, operation: "ALTER USER REQUIRE")
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

    func isMariaDB() async throws -> Bool {
        let connection = try await serverConnection.primary()
        let rows = try await connection.simpleQuery("SELECT VERSION() AS version")
        return MySQLReplicationClient.ServerFlavor(version: rows.first?.field("version")?.string ?? "").isMariaDB
    }

    func executeSecurityStatement(_ sql: String) async throws {
        let connection = try await serverConnection.primary()
        _ = try await connection.simpleQuery(sql)
    }

    func escapedLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
