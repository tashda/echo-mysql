
public struct MySQLExecutionPlanClient: Sendable {
    let serverConnection: MySQLServerConnection

    public func explain(_ sql: String) async throws -> MySQLExplainPlan {
        let connection = try await serverConnection.primary()
        let rows = try await connection.simpleQuery("EXPLAIN \(sql)")
        let planRows = rows.map { row in
            Dictionary(uniqueKeysWithValues: row.columnDefinitions.map { column in
                (column.name, row.column(column.name)?.string)
            })
        }
        return MySQLExplainPlan(rows: planRows)
    }

    public func explainJSON(_ sql: String) async throws -> MySQLExplainJSONPlan {
        let connection = try await serverConnection.primary()
        let rows = try await connection.simpleQuery("EXPLAIN FORMAT=JSON \(sql)")
        let json = rows.first?.field("EXPLAIN")?.string ?? "{}"
        return MySQLExplainJSONPlan(json: json)
    }

    public func explainAnalyze(_ sql: String) async throws -> MySQLExplainAnalyzePlan {
        let connection = try await serverConnection.primary()
        let rows = try await connection.simpleQuery("EXPLAIN ANALYZE \(sql)")
        let lines = rows.compactMap { row in
            row.columnDefinitions.first.flatMap { definition in
                row.column(definition.name)?.string
            }
        }
        return MySQLExplainAnalyzePlan(lines: lines)
    }
}
