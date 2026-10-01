
public struct MySQLPerformanceReport: Sendable, Hashable {
    public let name: String
    public let rows: [[String: String?]]

    public init(name: String, rows: [[String: String?]]) {
        self.name = name
        self.rows = rows
    }
}

public extension MySQLPerformanceClient {
    func runReport(_ reportSQL: String, name: String) async throws -> MySQLPerformanceReport {
        let connection = try await serverConnection.activity()
        let rows = try await connection.simpleQuery(reportSQL)
        let mappedRows = rows.map { row in
            Dictionary(uniqueKeysWithValues: row.columnDefinitions.map { column in
                (column.name, row.column(column.name)?.string)
            })
        }
        return MySQLPerformanceReport(name: name, rows: mappedRows)
    }

    func statementAnalysis(limit: Int = 10) async throws -> MySQLPerformanceReport {
        try await runReport(
            """
            SELECT * FROM sys.statement_analysis
            ORDER BY avg_latency DESC
            LIMIT \(limit)
            """,
            name: "statement_analysis"
        )
    }

    func unusedIndexes(limit: Int = 50) async throws -> MySQLPerformanceReport {
        try await runReport(
            """
            SELECT * FROM sys.schema_unused_indexes
            LIMIT \(limit)
            """,
            name: "schema_unused_indexes"
        )
    }
}
