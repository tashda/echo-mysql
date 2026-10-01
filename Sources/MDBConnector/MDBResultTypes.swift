import Foundation

/// A result column as the server describes it.
public struct MDBField: Sendable, Equatable {
    public init(name: String, originalName: String = "", table: String = "", originalTable: String = "", database: String = "",
                type: UInt32, flags: UInt32 = 0, decimals: UInt32 = 0, length: UInt64 = 0, charset: UInt32 = 255) {
        self.name = name
        self.originalName = originalName.isEmpty ? name : originalName
        self.table = table
        self.originalTable = originalTable
        self.database = database
        self.type = type
        self.flags = flags
        self.decimals = decimals
        self.length = length
        self.charset = charset
    }

    public let name: String
    public let originalName: String
    public let table: String
    public let originalTable: String
    public let database: String
    /// `enum_field_types` (MYSQL_TYPE_LONG = 3, MYSQL_TYPE_NEWDECIMAL = 246 …).
    public let type: UInt32
    /// `NOT_NULL_FLAG`, `PRI_KEY_FLAG`, `UNSIGNED_FLAG`, `BINARY_FLAG` …
    public let flags: UInt32
    public let decimals: UInt32
    public let length: UInt64
    /// The column's character set number (63 = binary).
    public let charset: UInt32

    public var isBinary: Bool { charset == 63 }
    public var isUnsigned: Bool { flags & 32 != 0 }
}

/// One row: each cell's bytes as the server sent them (text protocol), or NULL.
public struct MDBRow: Sendable, Equatable {
    let storage: Data
    /// Start offset of each cell in `storage`, or -1 for NULL; `ends[i]` its end.
    let starts: [Int]
    let ends: [Int]

    init(storage: Data, starts: [Int], ends: [Int]) {
        self.storage = storage
        self.starts = starts
        self.ends = ends
    }

    /// A row made from cells (tests, and rows built without a server).
    public init(cells: [Data?]) {
        var storage = Data(), starts: [Int] = [], ends: [Int] = []
        for cell in cells {
            guard let cell else { starts.append(-1); ends.append(-1); continue }
            starts.append(storage.count)
            storage.append(cell)
            ends.append(storage.count)
        }
        self.init(storage: storage, starts: starts, ends: ends)
    }

    public var count: Int { starts.count }

    public func isNull(_ column: Int) -> Bool { starts[column] < 0 }

    /// The cell's bytes; nil for NULL.
    public func data(_ column: Int) -> Data? {
        guard starts[column] >= 0 else { return nil }
        return storage.subdata(in: storage.startIndex + starts[column] ..< storage.startIndex + ends[column])
    }

    /// The cell's bytes without copying, valid inside `body`; nil for NULL.
    public func withBytes<R>(_ column: Int, _ body: (UnsafeRawBufferPointer?) throws -> R) rethrows -> R {
        guard starts[column] >= 0 else { return try body(nil) }
        return try storage.withUnsafeBytes { all in
            try body(UnsafeRawBufferPointer(rebasing: all[starts[column]..<ends[column]]))
        }
    }

    /// The cell as UTF-8 text; nil for NULL.
    public func string(_ column: Int) -> String? {
        withBytes(column) { $0.map { String(decoding: $0, as: UTF8.self) } }
    }
}

/// What a statement without rows did (and a row statement's totals at its end).
public struct MDBCommandResult: Sendable, Equatable {
    public let affectedRows: UInt64
    public let insertID: UInt64
    public let warningCount: UInt32
    /// "Records: 3  Duplicates: 0  Warnings: 0" and the like.
    public let info: String?
    /// Whether the statement returned rows (a SELECT that returned none still did).
    public let returnedRows: Bool
}

/// The results of SQL as they are read: a row set's columns, then its rows in batches, then its
/// end; or a command's end. Several statements give several of these in order.
public enum MDBEvent: Sendable, Equatable {
    case columns([MDBField])
    case rows([MDBRow])
    case done(MDBCommandResult)
}
