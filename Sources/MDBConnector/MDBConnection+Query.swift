#if canImport(CMariaDB)
internal import CMariaDB
#else
internal import CMariaDBSystem
#endif
import Foundation

extension MDBConnection {
    /// Sends SQL (several statements allowed) and waits until the server answers the first; then
    /// read the results with `nextEvent()` until it returns nil.
    public func send(_ sql: String) async throws {
        guard let mysql = handle else { throw MDBError(.notReady, message: "The connection is closed.") }
        guard !isBusy else { throw MDBError(.notReady, message: "The connection is still reading the results of another statement.") }
        // Connector/C keeps the pointer until the send is done.
        let utf8 = Array(sql.utf8)
        let text = UnsafeMutablePointer<CChar>.allocate(capacity: max(1, utf8.count))
        defer { text.deallocate() }
        utf8.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { UnsafeMutableRawPointer(text).copyMemory(from: base, byteCount: utf8.count) }
        }
        var status: Int32 = 0
        try await drive {
            mysql_real_query_start(&status, mysql, text, UInt(utf8.count))
        } resume: { ready in
            mysql_real_query_cont(&status, mysql, ready)
        }
        guard status == 0 else { throw self.error() }
        isBusy = true
        phase = .resultPending
    }

    /// The next part of the results, or nil when every statement has been read. Rows come in
    /// batches of up to `maxRows`; nothing is read from the socket until asked.
    public func nextEvent(maxRows: Int = 256) async throws -> MDBEvent? {
        guard let mysql = handle else { throw MDBError(.connectionLost, message: "The connection is closed.") }
        while true {
            switch phase {
            case .idle:
                isBusy = false
                return nil
            case .resultPending:
                if mysql_field_count(mysql) > 0 {
                    guard let opened = mysql_use_result(mysql) else { throw fail(self.error()) }
                    result = opened
                    currentFields = Self.fields(of: opened)
                    phase = .rows
                    return .columns(currentFields)
                }
                phase = .afterResult
                return .done(commandResult(returnedRows: false))
            case .rows:
                let rows = try await fetchRows(max: maxRows)
                if !rows.isEmpty { return .rows(rows) }
                if mysql_errno(mysql) != 0 { throw fail(self.error()) }
                try await freeResult()
                phase = .afterResult
                return .done(commandResult(returnedRows: true))
            case .afterResult:
                guard mysql_more_results(mysql) != 0 else {
                    phase = .idle
                    continue
                }
                var status: Int32 = 0
                try await drive {
                    mysql_next_result_start(&status, mysql)
                } resume: { ready in
                    mysql_next_result_cont(&status, mysql, ready)
                }
                if status > 0 { throw fail(self.error()) }
                phase = status == 0 ? .resultPending : .idle
            }
        }
    }

    /// Runs SQL and returns all its events, for short statements.
    public func execute(_ sql: String) async throws -> [MDBEvent] {
        try await send(sql)
        var events: [MDBEvent] = []
        while let event = try await nextEvent() { events.append(event) }
        return events
    }

    /// Reads and drops what is left of the statement(s) sent; errors in them are ignored.
    public func drain() async {
        while isBusy {
            do {
                guard try await nextEvent(maxRows: 4096) != nil else { return }
            } catch {
                if !isOpen { return }
            }
        }
    }

    // MARK: Internals

    enum Phase { case idle, resultPending, rows, afterResult }

    /// After an error the remaining results of the batch are gone (the server stops there).
    private func fail(_ error: MDBError) -> MDBError {
        if let result { mysql_free_result(result) }
        result = nil
        phase = .idle
        isBusy = false
        return error
    }

    private func fetchRows(max: Int) async throws -> [MDBRow] {
        guard let result else { return [] }
        let columns = Int(mysql_num_fields(result))
        var rows: [MDBRow] = []
        rows.reserveCapacity(min(max, 256))
        while rows.count < max {
            var row: MYSQL_ROW?
            try await drive {
                mysql_fetch_row_start(&row, result)
            } resume: { ready in
                mysql_fetch_row_cont(&row, result, ready)
            }
            guard let row, let lengths = mysql_fetch_lengths(result) else { break }
            var storage = Data()
            var starts = [Int](repeating: -1, count: columns), ends = [Int](repeating: -1, count: columns)
            for column in 0..<columns {
                guard let cell = row[column] else { continue }
                let length = Int(lengths[column])
                starts[column] = storage.count
                storage.append(UnsafeRawPointer(cell).assumingMemoryBound(to: UInt8.self), count: length)
                ends[column] = storage.count
            }
            rows.append(MDBRow(storage: storage, starts: starts, ends: ends))
        }
        return rows
    }

    private func freeResult() async throws {
        guard let result else { return }
        try await drive {
            mysql_free_result_start(result)
        } resume: { ready in
            mysql_free_result_cont(result, ready)
        }
        self.result = nil
    }

    private func commandResult(returnedRows: Bool) -> MDBCommandResult {
        guard let mysql = handle else { return MDBCommandResult(affectedRows: 0, insertID: 0, warningCount: 0, info: nil, returnedRows: returnedRows) }
        let affected = mysql_affected_rows(mysql)
        return MDBCommandResult(
            affectedRows: affected == UInt64.max ? 0 : affected,
            insertID: mysql_insert_id(mysql),
            warningCount: mysql_warning_count(mysql),
            info: mysql_info(mysql).map { String(cString: $0) },
            returnedRows: returnedRows
        )
    }

    static func fields(of result: UnsafeMutablePointer<MYSQL_RES>) -> [MDBField] {
        let count = Int(mysql_num_fields(result))
        guard count > 0, let fields = mysql_fetch_fields(result) else { return [] }
        func text(_ pointer: UnsafeMutablePointer<CChar>?, _ length: UInt32) -> String {
            guard let pointer else { return "" }
            return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(length)), as: UTF8.self)
        }
        return (0..<count).map { index in
            let field = fields[index]
            return MDBField(
                name: text(field.name, field.name_length),
                originalName: text(field.org_name, field.org_name_length),
                table: text(field.table, field.table_length),
                originalTable: text(field.org_table, field.org_table_length),
                database: text(field.db, field.db_length),
                type: UInt32(field.type.rawValue),
                flags: UInt32(field.flags),
                decimals: UInt32(field.decimals),
                length: UInt64(field.length),
                charset: UInt32(field.charsetnr)
            )
        }
    }
}
