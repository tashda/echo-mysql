import Foundation
import MySQLWire

public extension MySQLSessionClient {
    func currentUser() async throws -> String? {
        let connection = try await serverConnection.primary()
        let rows = try await connection.simpleQuery("SELECT CURRENT_USER() AS current_user")
        return rows.first?.field("current_user")?.string
    }

    func currentDatabase() async throws -> String? {
        let connection = try await serverConnection.primary()
        return try await connection.currentDatabase()
    }

    func sessionVariables(named names: [String]? = nil) async throws -> [MySQLSessionVariable] {
        let connection = try await serverConnection.primary()
        let rows = try await connection.simpleQuery("SHOW SESSION VARIABLES")
        let requestedNames = names.map { Set($0.map { $0.lowercased() }) }

        return rows.compactMap { row -> MySQLSessionVariable? in
            guard
                let name = row.field("Variable_name")?.string,
                let value = row.field("Value")?.string
            else {
                return nil
            }

            if let requestedNames, !requestedNames.contains(name.lowercased()) {
                return nil
            }

            return MySQLSessionVariable(name: name, value: value)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func setSessionVariable(name: String, value: String?) async throws -> MySQLSessionVariable {
        let renderedValue = value.map { "'\(MySQLBindRenderer.escapeStringLiteral($0))'" } ?? "DEFAULT"
        let connection = try await serverConnection.primary()
        _ = try await connection.simpleQuery("SET SESSION `\(escapedIdentifier(name))` = \(renderedValue)")
        let resolvedValue = value ?? "DEFAULT"
        return MySQLSessionVariable(name: name, value: resolvedValue)
    }

    func sqlMode() async throws -> String? {
        try await sessionVariables(named: ["sql_mode"]).first?.value
    }

    func setSQLMode(_ sqlMode: String?) async throws -> MySQLSessionVariable {
        try await setSessionVariable(name: "sql_mode", value: sqlMode)
    }

    func transactionIsolationLevel() async throws -> MySQLTransactionIsolationLevel? {
        let connection = try await serverConnection.primary()
        let rows = try await connection.simpleQuery(
            "SELECT @@SESSION.transaction_isolation AS transaction_isolation"
        )
        guard let rawLevel = rows.first?.field("transaction_isolation")?.string else {
            return nil
        }
        return MySQLTransactionIsolationLevel(rawValue: rawLevel.uppercased())
    }

    func setTransactionIsolationLevel(_ level: MySQLTransactionIsolationLevel) async throws {
        let connection = try await serverConnection.primary()
        _ = try await connection.simpleQuery("SET SESSION TRANSACTION ISOLATION LEVEL \(level.rawValue)")
    }

    private func escapedIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "`", with: "``")
    }
}
