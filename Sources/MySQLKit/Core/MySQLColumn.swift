import MDBConnector

/// A column type as the protocol numbers it (`MYSQL_TYPE_*`).
public struct MySQLDataType: RawRepresentable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let decimal = Self(rawValue: 0), tiny = Self(rawValue: 1), short = Self(rawValue: 2), long = Self(rawValue: 3)
    public static let float = Self(rawValue: 4), double = Self(rawValue: 5), null = Self(rawValue: 6), timestamp = Self(rawValue: 7)
    public static let longlong = Self(rawValue: 8), int24 = Self(rawValue: 9), date = Self(rawValue: 10), time = Self(rawValue: 11)
    public static let datetime = Self(rawValue: 12), year = Self(rawValue: 13), newdate = Self(rawValue: 14), varchar = Self(rawValue: 15)
    public static let bit = Self(rawValue: 16), json = Self(rawValue: 245), newdecimal = Self(rawValue: 246), `enum` = Self(rawValue: 247)
    public static let set = Self(rawValue: 248), tinyBlob = Self(rawValue: 249), mediumBlob = Self(rawValue: 250), longBlob = Self(rawValue: 251)
    public static let blob = Self(rawValue: 252), varString = Self(rawValue: 253), string = Self(rawValue: 254), geometry = Self(rawValue: 255)

    /// The `MYSQL_TYPE_*` name without its prefix, in lower case (`long`, `newdecimal`,
    /// `var_string`): the names Echo has always shown.
    public var name: String {
        switch rawValue {
        case 0: "decimal"; case 1: "tiny"; case 2: "short"; case 3: "long"; case 4: "float"; case 5: "double"
        case 6: "null"; case 7: "timestamp"; case 8: "longlong"; case 9: "int24"; case 10: "date"; case 11: "time"
        case 12: "datetime"; case 13: "year"; case 14: "newdate"; case 15: "varchar"; case 16: "bit"
        case 17: "timestamp2"; case 18: "datetime2"; case 19: "time2"
        case 245: "json"; case 246: "newdecimal"; case 247: "enum"; case 248: "set"; case 249: "tiny_blob"
        case 250: "medium_blob"; case 251: "long_blob"; case 252: "blob"; case 253: "var_string"; case 254: "string"
        case 255: "geometry"
        default: "type_\(rawValue)"
        }
    }

    public var description: String { "MYSQL_TYPE_" + name.uppercased() }
}

/// Column flags (`NOT_NULL_FLAG` …).
public struct MySQLColumnFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    public static let notNull = Self(rawValue: 1), primaryKey = Self(rawValue: 2), uniqueKey = Self(rawValue: 4)
    public static let multipleKey = Self(rawValue: 8), blob = Self(rawValue: 16), unsigned = Self(rawValue: 32)
    public static let zerofill = Self(rawValue: 64), binary = Self(rawValue: 128), `enum` = Self(rawValue: 256)
    public static let autoIncrement = Self(rawValue: 512), timestamp = Self(rawValue: 1024), set = Self(rawValue: 2048)
}

/// A result column as the server describes it.
public struct MySQLColumn: Hashable, Sendable {
    public let name: String
    public let originalName: String
    public let table: String
    public let originalTable: String
    public let schema: String
    public let columnType: MySQLDataType
    public let flags: MySQLColumnFlags
    public let decimals: UInt32
    public let columnLength: UInt64
    /// Character set number; 63 is binary.
    public let characterSet: UInt32

    public var isBinary: Bool { characterSet == 63 }

    init(_ field: MDBField) {
        name = field.name
        originalName = field.originalName
        table = field.table
        originalTable = field.originalTable
        schema = field.database
        columnType = MySQLDataType(rawValue: UInt8(truncatingIfNeeded: field.type))
        flags = MySQLColumnFlags(rawValue: field.flags)
        decimals = field.decimals
        columnLength = field.length
        characterSet = field.charset
    }
}

extension MySQLColumn {
    /// The column's SQL type as MySQL writes it (`BIGINT UNSIGNED`, `DECIMAL(65,30)`, `VARCHAR`,
    /// `VARBINARY`, `DATETIME`, `BIT(8)` …), worked out from the protocol type, flags and
    /// character set. Text and binary types share protocol codes; the binary character set (63)
    /// tells them apart.
    public var sqlTypeName: String {
        let unsigned = flags.contains(.unsigned) ? " UNSIGNED" : ""
        switch columnType {
        case .tiny: return "TINYINT" + unsigned
        case .short: return "SMALLINT" + unsigned
        case .int24: return "MEDIUMINT" + unsigned
        case .long: return "INT" + unsigned
        case .longlong: return "BIGINT" + unsigned
        case .float: return "FLOAT" + unsigned
        case .double: return "DOUBLE" + unsigned
        case .decimal, .newdecimal:
            // The display length counts the digits plus the sign and the decimal point.
            let scale = Int(decimals)
            let precision = max(1, Int(columnLength) - (scale > 0 ? 1 : 0) - (flags.contains(.unsigned) ? 0 : 1))
            return "DECIMAL(\(precision),\(scale))" + unsigned
        case .date, .newdate: return "DATE"
        case .time, MySQLDataType(rawValue: 19): return "TIME"
        case .datetime, MySQLDataType(rawValue: 18): return "DATETIME"
        case .timestamp, MySQLDataType(rawValue: 17): return "TIMESTAMP"
        case .year: return "YEAR"
        case .bit: return columnLength <= 1 ? "BIT" : "BIT(\(columnLength))"
        case .json: return "JSON"
        case .geometry: return "GEOMETRY"
        case .null: return "NULL"
        case .enum: return "ENUM"
        case .set: return "SET"
        case .tinyBlob, .mediumBlob, .longBlob, .blob:
            return isBinary ? "BLOB" : "TEXT"
        case .varchar, .varString:
            if flags.contains(.enum) { return "ENUM" }
            if flags.contains(.set) { return "SET" }
            return isBinary ? "VARBINARY" : "VARCHAR"
        case .string:
            if flags.contains(.enum) { return "ENUM" }
            if flags.contains(.set) { return "SET" }
            return isBinary ? "BINARY" : "CHAR"
        default:
            return columnType.name.uppercased()
        }
    }
}
