public struct MySQLEventClient: Sendable {
    let serverConnection: MySQLServerConnection

    public func createEvent(
        schema: String,
        name: String,
        scheduleSQL: String,
        bodySQL: String,
        preserveOnCompletion: Bool = true,
        enabled: Bool = true
    ) async throws {
        let completionClause = preserveOnCompletion ? "ON COMPLETION PRESERVE" : "ON COMPLETION NOT PRESERVE"
        let stateClause = enabled ? "ENABLE" : "DISABLE"
        try await executeDDL(
            "CREATE EVENT `\(escapedIdentifier(schema))`.`\(escapedIdentifier(name))` ON SCHEDULE \(scheduleSQL) \(completionClause) \(stateClause) DO \(bodySQL)"
        )
    }

    public func alterEvent(
        schema: String,
        name: String,
        scheduleSQL: String? = nil,
        bodySQL: String? = nil,
        enabled: Bool? = nil
    ) async throws {
        var clauses: [String] = []
        if let scheduleSQL, !scheduleSQL.isEmpty {
            clauses.append("ON SCHEDULE \(scheduleSQL)")
        }
        if let enabled {
            clauses.append(enabled ? "ENABLE" : "DISABLE")
        }
        if let bodySQL, !bodySQL.isEmpty {
            clauses.append("DO \(bodySQL)")
        }

        try await executeDDL(
            "ALTER EVENT `\(escapedIdentifier(schema))`.`\(escapedIdentifier(name))` \(clauses.joined(separator: " "))"
        )
    }

    public func dropEvent(schema: String, name: String, ifExists: Bool = true) async throws {
        let existsClause = ifExists ? "IF EXISTS " : ""
        try await executeDDL(
            "DROP EVENT \(existsClause)`\(escapedIdentifier(schema))`.`\(escapedIdentifier(name))`"
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
