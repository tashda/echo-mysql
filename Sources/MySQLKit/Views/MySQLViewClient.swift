public struct MySQLViewClient: Sendable {
    let serverConnection: MySQLServerConnection

    public enum Algorithm: String, Sendable { case undefined = "UNDEFINED", merge = "MERGE", temptable = "TEMPTABLE" }
    public enum SQLSecurity: String, Sendable { case definer = "DEFINER", invoker = "INVOKER" }
    public enum CheckOption: String, Sendable { case cascaded = "CASCADED", local = "LOCAL" }

    /// `definer` is `user@host` written as two parts; an account that does not exist is allowed
    /// (the server warns), which makes a view that fails for everyone but its owner's admins.
    public func createView(
        schema: String,
        name: String,
        definitionSQL: String,
        replace: Bool = false,
        algorithm: Algorithm? = nil,
        definer: (user: String, host: String)? = nil,
        sqlSecurity: SQLSecurity? = nil,
        checkOption: CheckOption? = nil
    ) async throws {
        try await executeDDL(Self.createViewSQL(schema: schema, name: name, definitionSQL: definitionSQL, replace: replace,
                                                algorithm: algorithm, definer: definer, sqlSecurity: sqlSecurity, checkOption: checkOption))
    }

    static func createViewSQL(schema: String, name: String, definitionSQL: String, replace: Bool, algorithm: Algorithm?,
                              definer: (user: String, host: String)?, sqlSecurity: SQLSecurity?, checkOption: CheckOption?) -> String {
        func literal(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
        var parts = [replace ? "CREATE OR REPLACE" : "CREATE"]
        if let algorithm { parts.append("ALGORITHM = \(algorithm.rawValue)") }
        if let definer { parts.append("DEFINER = \(literal(definer.user))@\(literal(definer.host))") }
        if let sqlSecurity { parts.append("SQL SECURITY \(sqlSecurity.rawValue)") }
        parts.append("VIEW `\(schema.replacingOccurrences(of: "`", with: "``"))`.`\(name.replacingOccurrences(of: "`", with: "``"))` AS \(definitionSQL)")
        if let checkOption { parts.append("WITH \(checkOption.rawValue) CHECK OPTION") }
        return parts.joined(separator: " ")
    }

    public func alterView(
        schema: String,
        name: String,
        definitionSQL: String
    ) async throws {
        try await executeDDL(
            "ALTER VIEW `\(escapedIdentifier(schema))`.`\(escapedIdentifier(name))` AS \(definitionSQL)"
        )
    }

    public func dropView(schema: String, name: String, ifExists: Bool = true) async throws {
        let existsClause = ifExists ? "IF EXISTS " : ""
        try await executeDDL(
            "DROP VIEW \(existsClause)`\(escapedIdentifier(schema))`.`\(escapedIdentifier(name))`"
        )
    }

    private func executeDDL(_ sql: String) async throws {
        let connection = try await serverConnection.primary()
        _ = try await connection.simpleQuery(sql)
    }

    private func escapedIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "`", with: "``")
    }
}
