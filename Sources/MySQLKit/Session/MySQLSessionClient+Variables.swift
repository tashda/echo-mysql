import Foundation

public extension MySQLSessionClient {
    func currentUser() async throws -> String? {
        let connection = try await serverConnection.primary()
        // CURRENT_USER is a reserved word, so it cannot be the column's alias.
        let rows = try await connection.simpleQuery("SELECT CURRENT_USER() AS account")
        return rows.first?.field("account")?.string
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
        // Numbers go unquoted: numeric variables refuse a string ("Incorrect argument type").
        // Text is a parameter, escaped by the connection for its character set and sql_mode.
        let connection = try await serverConnection.primary()
        let statement = "SET SESSION `\(escapedIdentifier(name))` = "
        switch value {
        case let value? where Self.isNumericLiteral(value):
            _ = try await connection.simpleQuery(statement + value)
        case let value?:
            _ = try await connection.query(statement + "?", binds: [MySQLData(string: value)])
        case nil:
            _ = try await connection.simpleQuery(statement + "DEFAULT")
        }
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
        // transaction_isolation on MySQL and MariaDB 11.1+; tx_isolation on older MariaDB.
        let rows = try await connection.simpleQuery(
            "SHOW SESSION VARIABLES WHERE Variable_name IN ('transaction_isolation', 'tx_isolation')"
        )
        let values = Dictionary(rows.compactMap { row in
            row.field("Variable_name")?.string.map { ($0, row.field("Value")?.string) }
        }, uniquingKeysWith: { first, _ in first })
        guard let rawLevel = (values["transaction_isolation"] ?? values["tx_isolation"]) ?? nil else {
            return nil
        }
        // The variable reads REPEATABLE-READ; the statement and the enum say REPEATABLE READ.
        return MySQLTransactionIsolationLevel(rawValue: rawLevel.uppercased().replacingOccurrences(of: "-", with: " "))
    }

    func setTransactionIsolationLevel(_ level: MySQLTransactionIsolationLevel) async throws {
        let connection = try await serverConnection.primary()
        _ = try await connection.simpleQuery("SET SESSION TRANSACTION ISOLATION LEVEL \(level.rawValue)")
    }

    private static func isNumericLiteral(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-") }
            && Double(value) != nil
    }

    private func escapedIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "`", with: "``")
    }
}
