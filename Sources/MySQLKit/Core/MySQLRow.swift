import Foundation
import MDBConnector

/// One row of a result.
public struct MySQLRow: Sendable {
    public let columnDefinitions: [MySQLColumn]
    let row: MDBRow

    init(columns: [MySQLColumn], row: MDBRow) {
        columnDefinitions = columns
        self.row = row
    }

    /// A row of text values made without a server (tests, previews).
    public init(textColumns: [(name: String, value: String?)]) {
        columnDefinitions = textColumns.map { MySQLColumn(MDBField(name: $0.name, type: UInt32(MySQLDataType.varString.rawValue))) }
        row = MDBRow(cells: textColumns.map { $0.value.map { Data($0.utf8) } })
    }

    public var count: Int { columnDefinitions.count }

    /// The value at a column position.
    public func value(at index: Int) -> MySQLData {
        let column = columnDefinitions[index]
        return MySQLData(type: column.columnType, bytes: row.data(index), isBinary: column.isBinary)
    }

    /// The first column with exactly this name.
    public func column(_ name: String) -> MySQLData? {
        columnDefinitions.firstIndex { $0.name == name }.map(value(at:))
    }

    /// A column by name, ignoring case. MySQL 8 and later label `information_schema` columns in
    /// upper case (`COLUMN_NAME`) whatever the query wrote; MariaDB keeps the query's case.
    public func field(_ name: String) -> MySQLData? {
        if let exact = column(name) { return exact }
        return columnDefinitions.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(value(at:))
    }

    /// Every value in column order.
    public var values: [MySQLData] { (0..<count).map(value(at:)) }

    /// A cell's bytes without copying, valid inside `body`; nil for NULL.
    public func withBytes<R>(at index: Int, _ body: (UnsafeRawBufferPointer?) throws -> R) rethrows -> R {
        try row.withBytes(index, body)
    }
}

/// All rows of one statement plus what it changed.
public struct MySQLWireQueryResult: Sendable {
    public let rows: [MySQLRow]
    public let metadata: MySQLWireQueryMetadata?
    /// Columns of the result set, also when it has no rows.
    public let columns: [MySQLColumn]

    public init(rows: [MySQLRow], metadata: MySQLWireQueryMetadata?, columns: [MySQLColumn] = []) {
        self.rows = rows
        self.metadata = metadata
        self.columns = columns.isEmpty ? (rows.first?.columnDefinitions ?? []) : columns
    }
}

public struct MySQLWireQueryMetadata: Sendable {
    public let affectedRows: UInt64
    public let lastInsertID: UInt64?
    public var warningCount: UInt32 = 0
    public var info: String?

    public init(affectedRows: UInt64, lastInsertID: UInt64?) {
        self.affectedRows = affectedRows
        self.lastInsertID = lastInsertID
    }
}
