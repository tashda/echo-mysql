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

    var clause: String { clause(backslashEscapes: true) }

    func clause(backslashEscapes: Bool) -> String {
        func quoted(_ text: String) -> String { "'" + escapedSQLLiteral(text, backslashEscapes: backslashEscapes) + "'" }
        switch self {
        case .none: return ""
        case .ssl: return " REQUIRE SSL"
        case .x509: return " REQUIRE X509"
        case .subject(let subject): return " REQUIRE SUBJECT \(quoted(subject))"
        case .issuer(let issuer): return " REQUIRE ISSUER \(quoted(issuer))"
        }
    }

    var text: String? {
        switch self {
        case .subject(let text), .issuer(let text): return text
        case .none, .ssl, .x509: return nil
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
        let backslashEscapes = try await backslashEscapes(for: [username, host, password, tls.text])
        try await executeSecurityStatement(createUserSQL(username: username, host: host, password: password,
                                                        authenticationPlugin: authenticationPlugin, mariaDB: mariaDB,
                                                        backslashEscapes: backslashEscapes)
                                           + tls.clause(backslashEscapes: backslashEscapes))
        return MySQLUserMutationResult(username: username, host: host, operation: "CREATE USER")
    }

    /// `IDENTIFIED BY` needs `IDENTIFIED` also without a plugin; it was left out, so a user with a
    /// password and no plugin could not be created. MariaDB takes a plugin's password as
    /// `IDENTIFIED VIA plugin USING PASSWORD('…')` (`ed25519`, `parsec`, `mysql_native_password`).
    internal func createUserSQL(username: String, host: String, password: String?, authenticationPlugin: String?,
                                mariaDB: Bool = false, backslashEscapes: Bool = true) -> String {
        func escapedLiteral(_ value: String) -> String { escapedSQLLiteral(value, backslashEscapes: backslashEscapes) }
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
        let escapedLiteral = try await literalEscaper(for: [username, host])
        try await executeSecurityStatement(
            "DROP USER \(existsClause)'\(escapedLiteral(username))'@'\(escapedLiteral(host))'"
        )
        return MySQLUserMutationResult(username: username, host: host, operation: "DROP USER")
    }

    /// Changes what TLS an account must log in with (`ALTER USER … REQUIRE …`).
    @discardableResult
    func alterUserTLS(username: String, host: String, tls: MySQLTLSRequirement) async throws -> MySQLUserMutationResult {
        let backslashEscapes = try await backslashEscapes(for: [username, host, tls.text])
        let escapedLiteral = literalEscaper(backslashEscapes: backslashEscapes)
        let clause = tls == .none ? " REQUIRE NONE" : tls.clause(backslashEscapes: backslashEscapes)
        try await executeSecurityStatement("ALTER USER '\(escapedLiteral(username))'@'\(escapedLiteral(host))'\(clause)")
        return MySQLUserMutationResult(username: username, host: host, operation: "ALTER USER REQUIRE")
    }

    func alterUserPassword(username: String, host: String, password: String) async throws -> MySQLUserMutationResult {
        let escapedLiteral = try await literalEscaper(for: [username, host, password])
        try await executeSecurityStatement(
            "ALTER USER '\(escapedLiteral(username))'@'\(escapedLiteral(host))' IDENTIFIED BY '\(escapedLiteral(password))'"
        )
        return MySQLUserMutationResult(username: username, host: host, operation: "ALTER USER PASSWORD")
    }

    func lockUser(username: String, host: String) async throws -> MySQLUserMutationResult {
        let escapedLiteral = try await literalEscaper(for: [username, host])
        try await executeSecurityStatement(
            "ALTER USER '\(escapedLiteral(username))'@'\(escapedLiteral(host))' ACCOUNT LOCK"
        )
        return MySQLUserMutationResult(username: username, host: host, operation: "LOCK USER")
    }

    func unlockUser(username: String, host: String) async throws -> MySQLUserMutationResult {
        let escapedLiteral = try await literalEscaper(for: [username, host])
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
        let backslashEscapes = try await backslashEscapes(for: [username, host])
        try await executeSecurityStatement(
            "GRANT \(privilege) ON \(object) TO \(roleName(username, host: host, backslashEscapes: backslashEscapes))\(grantOptionClause)"
        )
    }

    func revoke(
        _ privilege: String,
        on object: String,
        from username: String,
        host: String?
    ) async throws {
        let backslashEscapes = try await backslashEscapes(for: [username, host])
        try await executeSecurityStatement(
            "REVOKE \(privilege) ON \(object) FROM \(roleName(username, host: host, backslashEscapes: backslashEscapes))"
        )
    }

    /// Creates a role. Without a host it works on MySQL (`'name'@'%'`) and MariaDB (whose roles have no host).
    func createRole(name: String, host: String? = nil) async throws {
        let backslashEscapes = try await backslashEscapes(for: [name, host])
        try await executeSecurityStatement("CREATE ROLE \(roleName(name, host: host, backslashEscapes: backslashEscapes))")
    }

    func dropRole(name: String, host: String? = nil) async throws {
        let backslashEscapes = try await backslashEscapes(for: [name, host])
        try await executeSecurityStatement("DROP ROLE \(roleName(name, host: host, backslashEscapes: backslashEscapes))")
    }

    internal func roleName(_ name: String, host: String?, backslashEscapes: Bool = true) -> String {
        let escapedLiteral = literalEscaper(backslashEscapes: backslashEscapes)
        return "'\(escapedLiteral(name))'" + (host.map { "@'\(escapedLiteral($0))'" } ?? "")
    }

    func grantRole(
        _ roleName: String,
        roleHost: String? = nil,
        to username: String,
        host: String
    ) async throws {
        let backslashEscapes = try await backslashEscapes(for: [roleName, roleHost, username, host])
        let escapedLiteral = literalEscaper(backslashEscapes: backslashEscapes)
        try await executeSecurityStatement(
            "GRANT \(self.roleName(roleName, host: roleHost, backslashEscapes: backslashEscapes)) TO '\(escapedLiteral(username))'@'\(escapedLiteral(host))'"
        )
    }

    func revokeRole(
        _ roleName: String,
        roleHost: String? = nil,
        from username: String,
        host: String
    ) async throws {
        let backslashEscapes = try await backslashEscapes(for: [roleName, roleHost, username, host])
        let escapedLiteral = literalEscaper(backslashEscapes: backslashEscapes)
        try await executeSecurityStatement(
            "REVOKE \(self.roleName(roleName, host: roleHost, backslashEscapes: backslashEscapes)) FROM '\(escapedLiteral(username))'@'\(escapedLiteral(host))'"
        )
    }

    /// Sets a user's default role. MariaDB roles have no host, so there `roleHost` is ignored.
    func setDefaultRole(
        _ roleName: String,
        roleHost: String = "%",
        for username: String,
        host: String
    ) async throws {
        let mariaDB = try await isMariaDB()
        let backslashEscapes = try await backslashEscapes(for: [roleName, roleHost, username, host])
        try await executeSecurityStatement(setDefaultRoleSQL(roleName, roleHost: roleHost, for: username, host: host,
                                                             mariaDB: mariaDB, backslashEscapes: backslashEscapes))
    }

    /// MySQL: `SET DEFAULT ROLE 'role'@'host' TO 'user'@'host'`.
    /// MariaDB: `SET DEFAULT ROLE 'role' FOR 'user'@'host'`.
    internal func setDefaultRoleSQL(_ roleName: String, roleHost: String, for username: String, host: String,
                                    mariaDB: Bool, backslashEscapes: Bool = true) -> String {
        let escapedLiteral = literalEscaper(backslashEscapes: backslashEscapes)
        let user = "'\(escapedLiteral(username))'@'\(escapedLiteral(host))'"
        if mariaDB {
            return "SET DEFAULT ROLE \(self.roleName(roleName, host: nil, backslashEscapes: backslashEscapes)) FOR \(user)"
        }
        return "SET DEFAULT ROLE \(self.roleName(roleName, host: roleHost, backslashEscapes: backslashEscapes)) TO \(user)"
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

    /// Whether a backslash escapes on the primary connection. Only a value with a backslash is
    /// written differently under `NO_BACKSLASH_ESCAPES`, so only then is `sql_mode` read.
    internal func backslashEscapes(for values: [String?]) async throws -> Bool {
        guard values.contains(where: { $0?.contains("\\") == true }) else { return true }
        let connection = try await serverConnection.primary()
        let rows = try await connection.simpleQuery("SELECT @@SESSION.sql_mode AS sql_mode")
        let modes = (rows.first?.field("sql_mode")?.string ?? "").uppercased().split(separator: ",")
        return !modes.contains("NO_BACKSLASH_ESCAPES")
    }

    internal func literalEscaper(for values: [String?]) async throws -> @Sendable (String) -> String {
        literalEscaper(backslashEscapes: try await backslashEscapes(for: values))
    }

    internal func literalEscaper(backslashEscapes: Bool) -> @Sendable (String) -> String {
        { escapedSQLLiteral($0, backslashEscapes: backslashEscapes) }
    }
}

/// Escapes text for a single-quoted SQL literal: quotes are doubled, and backslashes too unless
/// `NO_BACKSLASH_ESCAPES` is on (then a backslash is an ordinary character).
func escapedSQLLiteral(_ value: String, backslashEscapes: Bool) -> String {
    let quoted = value.replacingOccurrences(of: "'", with: "''")
    return backslashEscapes ? quoted.replacingOccurrences(of: "\\", with: "\\\\") : quoted
}
