import MySQLWire

public struct MySQLServerConfigClient: Sendable {
    let serverConnection: MySQLServerConnection

    /// SHOW takes no parameter markers, so the pattern (a name, or a LIKE pattern) is a literal.
    static func globalVariablesSQL(named variableName: String?) -> String {
        guard let variableName, !variableName.isEmpty else { return "SHOW GLOBAL VARIABLES" }
        let literal = variableName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''")
        return "SHOW GLOBAL VARIABLES LIKE '\(literal)'"
    }

    public func globalVariables(named variableName: String? = nil) async throws -> [MySQLGlobalVariable] {
        let connection = try await serverConnection.activity()
        let result = try await connection.query(Self.globalVariablesSQL(named: variableName), binds: [])
        return result.rows.compactMap { row in
            guard
                let name = row.field("Variable_name")?.string,
                let value = row.field("Value")?.string
            else {
                return nil
            }
            return MySQLGlobalVariable(name: name, value: value)
        }
    }

    /// Like `globalVariablesSQL`: SHOW takes no parameter markers.
    static func globalStatusSQL(named variableName: String?) -> String {
        guard let variableName, !variableName.isEmpty else { return "SHOW GLOBAL STATUS" }
        let literal = variableName.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''")
        return "SHOW GLOBAL STATUS LIKE '\(literal)'"
    }

    public func globalStatus(named variableName: String? = nil) async throws -> [MySQLStatusVariable] {
        let sql = Self.globalStatusSQL(named: variableName)
        let connection = try await serverConnection.activity()
        let result = try await connection.query(sql, binds: [])
        return result.rows.compactMap { row in
            guard
                let name = row.field("Variable_name")?.string,
                let value = row.field("Value")?.string
            else {
                return nil
            }
            return MySQLStatusVariable(name: name, value: value)
        }
    }

    public func setGlobalVariable(_ name: String, to value: String) async throws -> MySQLServerVariableMutation {
        let connection = try await serverConnection.primary()
        _ = try await connection.simpleQuery("SET GLOBAL \(name) = \(value)")
        return MySQLServerVariableMutation(name: name, value: value)
    }

    public func resetGlobalVariable(_ name: String) async throws -> MySQLServerVariableMutation {
        let connection = try await serverConnection.primary()
        _ = try await connection.simpleQuery("SET GLOBAL \(name) = DEFAULT")
        return MySQLServerVariableMutation(name: name, value: nil)
    }
}
