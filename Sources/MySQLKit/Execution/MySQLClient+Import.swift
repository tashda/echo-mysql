import Foundation
import MDBConnector

/// How ``MySQLClient/importRows(into:schema:columns:rows:batchSize:afterBatch:)`` stored the rows.
public struct MySQLImportSummary: Sendable, Equatable {
    public enum Method: Sendable, Equatable {
        /// `LOAD DATA LOCAL INFILE` (decision D17).
        case loadDataLocal
        /// Multi-row INSERTs: the server doesn't allow `local_infile`.
        case insertStatements
    }

    public let method: Method
    public let rowCount: Int
    public let batches: Int
    /// Warnings that didn't stop the import (a server without strict mode keeps truncated values).
    public let warnings: [MySQLWarning]
}

/// Why an import stored nothing.
public enum MySQLImportError: LocalizedError, Equatable, Sendable {
    /// `LOAD DATA LOCAL` turns errors into warnings; the server's strict mode (or a duplicate key)
    /// would have refused these rows, so the import was rolled back.
    case rowsRejected([MySQLWarning])
    /// The server stored a different number of rows than were sent.
    case rowCountMismatch(sent: Int, stored: Int)

    public var errorDescription: String? {
        switch self {
        case .rowsRejected(let warnings):
            let first = warnings.first.map { "\($0.message) (\($0.code))" } ?? "the server rejected rows"
            return warnings.count > 1 ? "\(first), and \(warnings.count - 1) more" : first
        case .rowCountMismatch(let sent, let stored):
            return "The server stored \(stored) of \(sent) rows."
        }
    }
}

extension MySQLClient {
    /// Imports `rows` (nil is NULL) into a table, in one transaction on a connection of its own:
    /// every row or none, so a failure or a cancelled task leaves the table as it was. Uses
    /// `LOAD DATA LOCAL INFILE` when the server allows `local_infile` (decision D17: only on this
    /// connection, and only these rows can be read by the server), otherwise multi-row INSERTs.
    /// `afterBatch` gets the number of rows done so far.
    public func importRows(
        into table: String,
        schema: String? = nil,
        columns: [String],
        rows: [[String?]],
        batchSize: Int = 5000,
        afterBatch: @Sendable (Int) async throws -> Void = { _ in }
    ) async throws -> MySQLImportSummary {
        var importConfiguration = configuration
        importConfiguration.allowLocalInfile = true
        let connection = try await MySQLWireConnection.connect(configuration: importConfiguration)
        do {
            let summary = try await connection.importRows(
                MySQLImportRequest(table: table, schema: schema, columns: columns, batchSize: max(1, batchSize)),
                rows: rows, afterBatch: afterBatch
            )
            await connection.close()
            return summary
        } catch {
            // Closing the connection rolls the transaction back.
            await connection.close()
            throw error
        }
    }
}

struct MySQLImportRequest {
    let table: String
    let schema: String?
    let columns: [String]
    let batchSize: Int
}

extension MySQLWireConnection {
    static let importFileName = "echo-import.tsv"

    func importRows(
        _ request: MySQLImportRequest,
        rows: [[String?]],
        afterBatch: @Sendable (Int) async throws -> Void
    ) async throws -> MySQLImportSummary {
        let settings = try await query("SELECT @@GLOBAL.local_infile, @@SESSION.sql_mode").rows.first
        let localInfile = settings?.value(at: 0).int == 1
        let sqlMode = settings?.value(at: 1).string ?? ""
        let strict = sqlMode.contains("STRICT_TRANS_TABLES") || sqlMode.contains("STRICT_ALL_TABLES")
        _ = try await query("START TRANSACTION")
        var done = 0, batches = 0
        var kept: [MySQLWarning] = []
        while done < rows.count {
            try Task.checkCancellation()
            let batch = rows[done..<min(done + request.batchSize, rows.count)]
            let warnings: [MySQLWarning]
            if localInfile {
                let sql = MySQLLoadDataText.statement(table: request.table, schema: request.schema, columns: request.columns,
                                                      name: Self.importFileName, noBackslashEscapes: sqlMode.contains("NO_BACKSLASH_ESCAPES"))
                let result = try await loadLocal(sql, data: MySQLLoadDataText.render(batch))
                warnings = result.warningCount > 0 ? try await showWarnings() : []
                // LOCAL makes every error a warning (the server can't stop the upload): refuse what
                // INSERT would have refused.
                let refused = warnings.filter { $0.level != "Note" && (strict || $0.code == 1062) }
                guard refused.isEmpty else { throw MySQLImportError.rowsRejected(refused) }
                guard result.affectedRows == UInt64(batch.count) else {
                    throw MySQLImportError.rowCountMismatch(sent: batch.count, stored: Int(result.affectedRows))
                }
            } else {
                let placeholders = "(" + Array(repeating: "?", count: request.columns.count).joined(separator: ", ") + ")"
                let target = [request.schema, request.table].compactMap { $0 }.map(MySQLLoadDataText.quote).joined(separator: ".")
                let sql = "INSERT INTO \(target) (\(request.columns.map(MySQLLoadDataText.quote).joined(separator: ", "))) VALUES "
                    + Array(repeating: placeholders, count: batch.count).joined(separator: ", ")
                let binds = batch.flatMap { row in row.map { $0.map(MySQLData.init(string:)) ?? .null } }
                let result = try await query(sql, binds: binds)
                warnings = (result.metadata?.warningCount ?? 0) > 0 ? try await showWarnings() : []
            }
            kept += warnings.filter { $0.level != "Note" }
            done += batch.count
            batches += 1
            try await afterBatch(done)
        }
        _ = try await query("COMMIT")
        return MySQLImportSummary(method: localInfile ? .loadDataLocal : .insertStatements, rowCount: done, batches: batches, warnings: kept)
    }

    /// One `LOAD DATA LOCAL INFILE` statement, with `data` as its file.
    func loadLocal(_ sql: String, data: Data) async throws -> MDBCommandResult {
        await acquire()
        defer { release() }
        try await prepare()
        do {
            return try await connection.loadLocal(sql, name: Self.importFileName, data: data)
        } catch {
            throw MySQLError.from(error)
        }
    }

    func showWarnings() async throws -> [MySQLWarning] {
        try await query("SHOW WARNINGS").rows.map { row in
            MySQLWarning(level: row.column("Level")?.string ?? "Warning", code: row.column("Code")?.int ?? 0,
                         message: row.column("Message")?.string ?? "")
        }
    }
}
