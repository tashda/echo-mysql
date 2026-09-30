import MySQLWire

/// A column of a new table or an added column.
public struct MySQLColumnDefinition: Sendable, Hashable {
    public var name: String
    /// The type as MySQL writes it: `INT UNSIGNED`, `VARCHAR(255)`, `DECIMAL(10,2)`, `ENUM('a','b')`.
    public var dataType: String
    public var isNullable: Bool
    public var defaultValue: MySQLDefaultValue?
    public var isAutoIncrement: Bool
    public var generated: MySQLGeneratedColumn?
    public var characterSet: String?
    public var collation: String?
    public var comment: String?
    /// Hidden from `SELECT *` (MySQL 8.0.23+; MariaDB 10.3+).
    public var isInvisible: Bool
    /// The spatial reference system of a geometry column (MySQL 8.0+).
    public var srid: Int?

    public init(name: String, dataType: String, isNullable: Bool = true, defaultValue: MySQLDefaultValue? = nil,
                isAutoIncrement: Bool = false, generated: MySQLGeneratedColumn? = nil, characterSet: String? = nil,
                collation: String? = nil, comment: String? = nil, isInvisible: Bool = false, srid: Int? = nil) {
        self.name = name
        self.dataType = dataType
        self.isNullable = isNullable
        self.defaultValue = defaultValue
        self.isAutoIncrement = isAutoIncrement
        self.generated = generated
        self.characterSet = characterSet
        self.collation = collation
        self.comment = comment
        self.isInvisible = isInvisible
        self.srid = srid
    }
}

public enum MySQLDefaultValue: Sendable, Hashable {
    case null
    /// A quoted string literal.
    case string(String)
    case number(String)
    case currentTimestamp(precision: Int? = nil)
    /// An expression default (MySQL 8.0.13+), written in parentheses: `(UUID())`.
    case expression(String)
}

/// `GENERATED ALWAYS AS (expression) VIRTUAL|STORED`.
public struct MySQLGeneratedColumn: Sendable, Hashable {
    public var expression: String
    public var isStored: Bool

    public init(expression: String, isStored: Bool = false) {
        self.expression = expression
        self.isStored = isStored
    }
}

/// Table options after the column list.
public struct MySQLTableOptions: Sendable, Hashable {
    public var engine: String?
    public var characterSet: String?
    public var collation: String?
    public var comment: String?
    public var rowFormat: String?
    /// MariaDB system-versioned table (`WITH SYSTEM VERSIONING`).
    public var systemVersioning: Bool

    public init(engine: String? = nil, characterSet: String? = nil, collation: String? = nil, comment: String? = nil,
                rowFormat: String? = nil, systemVersioning: Bool = false) {
        self.engine = engine
        self.characterSet = characterSet
        self.collation = collation
        self.comment = comment
        self.rowFormat = rowFormat
        self.systemVersioning = systemVersioning
    }
}

/// A column of an index, with an optional prefix length and order.
public struct MySQLIndexColumn: Sendable, Hashable, ExpressibleByStringLiteral {
    public var name: String
    public var prefixLength: Int?
    public var isDescending: Bool

    public init(_ name: String, prefixLength: Int? = nil, isDescending: Bool = false) {
        self.name = name
        self.prefixLength = prefixLength
        self.isDescending = isDescending
    }

    public init(stringLiteral value: String) { self.init(value) }
}

public enum MySQLIndexKind: String, Sendable, Hashable, CaseIterable {
    case standard = ""
    case unique = "UNIQUE "
    case fulltext = "FULLTEXT "
    case spatial = "SPATIAL "
}

public enum MySQLReferentialAction: String, Sendable, Hashable, CaseIterable {
    case restrict = "RESTRICT"
    case cascade = "CASCADE"
    case setNull = "SET NULL"
    case noAction = "NO ACTION"
    case setDefault = "SET DEFAULT"
}

/// A value for `bulk.insertValues`: bound data, or a typed conversion around a bound parameter.
public enum MySQLInsertValue: Sendable {
    case data(MySQLData)
    case null
    /// `ST_GeomFromText(?, srid)` from well-known text.
    case geometry(wkt: String, srid: Int? = nil)
    /// `CAST(? AS JSON)` (MySQL); MariaDB stores JSON as text, so the value is bound as is there.
    case json(String)
    /// `STRING_TO_VECTOR(?)` (MySQL 9) / `VEC_FromText(?)` (MariaDB 11.7).
    case vector([Float], mariaDB: Bool = false)
    /// A `BIT` value.
    case bits(UInt64)

    var placeholder: String {
        switch self {
        case .data, .null, .bits: "?"
        case .geometry(_, let srid): srid.map { "ST_GeomFromText(?, \($0))" } ?? "ST_GeomFromText(?)"
        case .json: "CAST(? AS JSON)"
        case .vector(_, let mariaDB): mariaDB ? "VEC_FromText(?)" : "STRING_TO_VECTOR(?)"
        }
    }

    var bind: MySQLData {
        switch self {
        case .data(let data): data
        case .null: .null
        case .geometry(let wkt, _): MySQLData(string: wkt)
        case .json(let text): MySQLData(string: text)
        case .vector(let values, _): MySQLData(string: "[" + values.map { "\($0)" }.joined(separator: ",") + "]")
        case .bits(let value): MySQLData(int: Int(bitPattern: UInt(value)))
        }
    }
}
