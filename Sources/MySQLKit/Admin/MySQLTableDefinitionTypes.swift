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
    public var partitioning: MySQLPartitioning?

    public init(engine: String? = nil, characterSet: String? = nil, collation: String? = nil, comment: String? = nil,
                rowFormat: String? = nil, systemVersioning: Bool = false, partitioning: MySQLPartitioning? = nil) {
        self.engine = engine
        self.characterSet = characterSet
        self.collation = collation
        self.comment = comment
        self.rowFormat = rowFormat
        self.systemVersioning = systemVersioning
        self.partitioning = partitioning
    }
}

/// `PARTITION BY …` for a new table. Expressions and bounds are SQL (like view bodies).
public enum MySQLPartitioning: Sendable, Hashable {
    /// `RANGE (expression)`; a nil bound is `MAXVALUE`.
    case range(expression: String, partitions: [(name: String, lessThan: String?)])
    /// `RANGE COLUMNS (columns)`.
    case rangeColumns(columns: [String], partitions: [(name: String, lessThan: [String])])
    /// `LIST (expression)`.
    case list(expression: String, partitions: [(name: String, values: [String])])
    case hash(expression: String, count: Int)
    case key(columns: [String], count: Int)

    public static func == (lhs: MySQLPartitioning, rhs: MySQLPartitioning) -> Bool { lhs.sql == rhs.sql }
    public func hash(into hasher: inout Hasher) { hasher.combine(sql) }

    var sql: String {
        func names(_ columns: [String]) -> String { columns.map(MySQLTableSQL.identifier).joined(separator: ", ") }
        switch self {
        case .range(let expression, let partitions):
            return "PARTITION BY RANGE (\(expression)) (" + partitions.map {
                "PARTITION \(MySQLTableSQL.identifier($0.name)) VALUES LESS THAN \($0.lessThan.map { "(\($0))" } ?? "MAXVALUE")"
            }.joined(separator: ", ") + ")"
        case .rangeColumns(let columns, let partitions):
            return "PARTITION BY RANGE COLUMNS (\(names(columns))) (" + partitions.map {
                "PARTITION \(MySQLTableSQL.identifier($0.name)) VALUES LESS THAN (\($0.lessThan.joined(separator: ", ")))"
            }.joined(separator: ", ") + ")"
        case .list(let expression, let partitions):
            return "PARTITION BY LIST (\(expression)) (" + partitions.map {
                "PARTITION \(MySQLTableSQL.identifier($0.name)) VALUES IN (\($0.values.joined(separator: ", ")))"
            }.joined(separator: ", ") + ")"
        case .hash(let expression, let count):
            return "PARTITION BY HASH (\(expression)) PARTITIONS \(count)"
        case .key(let columns, let count):
            return "PARTITION BY KEY (\(names(columns))) PARTITIONS \(count)"
        }
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
    /// JSON text, bound as is: a JSON column parses it (MariaDB's JSON is LONGTEXT with a check).
    case json(String)
    /// `STRING_TO_VECTOR(?)` (MySQL 9) / `VEC_FromText(?)` (MariaDB 11.7).
    case vector([Float], mariaDB: Bool = false)
    /// A `BIT` value.
    case bits(UInt64)

    var placeholder: String {
        switch self {
        case .data, .null, .bits: "?"
        case .geometry(_, let srid): srid.map { "ST_GeomFromText(?, \($0))" } ?? "ST_GeomFromText(?)"
        // A JSON column parses the bound text itself; MariaDB has no CAST … AS JSON (its JSON is LONGTEXT).
        case .json: "?"
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
