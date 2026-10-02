public struct MySQLRoutineClient: Sendable {
    let serverConnection: MySQLServerConnection

    public func createRoutine(
        schema: String,
        name: String,
        kind: MySQLRoutineKind,
        parametersSQL: String = "",
        returnsSQL: String? = nil,
        characteristicsSQL: String? = nil,
        bodySQL: String
    ) async throws {
        var statement = "CREATE \(kind.rawValue) `\(escapedIdentifier(schema))`.`\(escapedIdentifier(name))`(\(parametersSQL))"
        if kind == .function, let returnsSQL, !returnsSQL.isEmpty {
            statement += " RETURNS \(returnsSQL)"
        }
        if let characteristicsSQL, !characteristicsSQL.isEmpty {
            statement += " \(characteristicsSQL)"
        }
        statement += " \(bodySQL)"
        try await executeDDL(statement)
    }

    public func dropRoutine(
        schema: String,
        name: String,
        kind: MySQLRoutineKind,
        ifExists: Bool = true
    ) async throws {
        let existsClause = ifExists ? "IF EXISTS " : ""
        try await executeDDL(
            "DROP \(kind.rawValue) \(existsClause)`\(escapedIdentifier(schema))`.`\(escapedIdentifier(name))`"
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
