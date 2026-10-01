import MySQLWire

public extension MySQLPerformanceClient {
    func topRuntimeStatements(limit: Int = 10) async throws -> MySQLPerformanceReport {
        try await runReport(
            """
            SELECT * FROM sys.statements_with_runtimes_in_95th_percentile
            LIMIT \(limit)
            """,
            name: "statements_with_runtimes_in_95th_percentile"
        )
    }

    func fullTableScans(limit: Int = 10) async throws -> MySQLPerformanceReport {
        try await runReport(
            """
            SELECT * FROM sys.statements_with_full_table_scans
            LIMIT \(limit)
            """,
            name: "statements_with_full_table_scans"
        )
    }

    func innodbStatus() async throws -> MySQLInnoDBStatus {
        let connection = try await serverConnection.activity()
        let rows = try await connection.simpleQuery("SHOW ENGINE INNODB STATUS")
        let status = rows.first?.field("Status")?.string ?? ""
        return MySQLInnoDBStatus(statusText: status)
    }

    func schemaIndexStatistics(limit: Int = 50) async throws -> MySQLPerformanceReport {
        try await runReport(
            """
            SELECT * FROM sys.schema_index_statistics
            LIMIT \(limit)
            """,
            name: "schema_index_statistics"
        )
    }

    func schemaTableStatistics(limit: Int = 50) async throws -> MySQLPerformanceReport {
        try await runReport(
            """
            SELECT * FROM sys.schema_table_statistics
            LIMIT \(limit)
            """,
            name: "schema_table_statistics"
        )
    }

    func waitsGlobalByLatency(limit: Int = 50) async throws -> MySQLPerformanceReport {
        try await runReport(
            """
            SELECT * FROM sys.waits_global_by_latency
            LIMIT \(limit)
            """,
            name: "waits_global_by_latency"
        )
    }

    func waitsByUserByLatency(limit: Int = 50) async throws -> MySQLPerformanceReport {
        try await runReport(
            """
            SELECT * FROM sys.waits_by_user_by_latency
            LIMIT \(limit)
            """,
            name: "waits_by_user_by_latency"
        )
    }

    func hostSummary(limit: Int = 50) async throws -> MySQLPerformanceReport {
        try await runReport(
            """
            SELECT * FROM sys.host_summary
            LIMIT \(limit)
            """,
            name: "host_summary"
        )
    }

    func memoryGlobalByCurrentBytes(limit: Int = 50) async throws -> MySQLPerformanceReport {
        try await runReport(
            """
            SELECT * FROM sys.memory_global_by_current_bytes
            LIMIT \(limit)
            """,
            name: "memory_global_by_current_bytes"
        )
    }

    func ioGlobalByFileByBytes(limit: Int = 50) async throws -> MySQLPerformanceReport {
        try await runReport(
            """
            SELECT * FROM sys.io_global_by_file_by_bytes
            LIMIT \(limit)
            """,
            name: "io_global_by_file_by_bytes"
        )
    }
}
