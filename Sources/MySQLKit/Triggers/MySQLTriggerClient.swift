public struct MySQLTriggerClient: Sendable {
    let serverConnection: MySQLServerConnection

    public func createTrigger(
        schema: String,
        name: String,
        timing: MySQLTriggerTiming,
        event: MySQLTriggerEvent,
        table: String,
        bodySQL: String
    ) async throws {
        try await executeDDL(
            "CREATE TRIGGER `\(escapedIdentifier(schema))`.`\(escapedIdentifier(name))` \(timing.rawValue) \(event.rawValue) ON `\(escapedIdentifier(schema))`.`\(escapedIdentifier(table))` FOR EACH ROW \(bodySQL)"
        )
    }

    public func dropTrigger(schema: String, name: String, ifExists: Bool = true) async throws {
        let existsClause = ifExists ? "IF EXISTS " : ""
        try await executeDDL(
            "DROP TRIGGER \(existsClause)`\(escapedIdentifier(schema))`.`\(escapedIdentifier(name))`"
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
