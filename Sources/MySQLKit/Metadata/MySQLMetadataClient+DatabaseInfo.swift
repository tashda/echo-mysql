
public extension MySQLMetadataClient {
    /// Returns size, charset, and collation info for a database schema.
    func databaseInfo(schema: String) async throws -> MySQLDatabaseInfo {
        let sql = """
        SELECT
            ROUND(SUM(t.data_length + t.index_length) / 1024 / 1024, 2) AS size_mb,
            s.DEFAULT_CHARACTER_SET_NAME AS charset,
            s.DEFAULT_COLLATION_NAME AS collation
        FROM information_schema.schemata s
        LEFT JOIN information_schema.tables t ON t.table_schema = s.schema_name
        WHERE s.schema_name = ?
        GROUP BY s.schema_name, s.DEFAULT_CHARACTER_SET_NAME, s.DEFAULT_COLLATION_NAME;
        """

        let connection = try await serverConnection.metadata()
        let result = try await connection.query(sql, binds: [MySQLData(string: schema)])
        guard let row = result.rows.first else {
            return MySQLDatabaseInfo(sizeMB: 0, characterSet: nil, collation: nil)
        }

        return MySQLDatabaseInfo(
            sizeMB: row.field("size_mb")?.string.flatMap(Double.init) ?? 0,
            characterSet: row.field("charset")?.string,
            collation: row.field("collation")?.string
        )
    }

    /// Loads all tables, views, and their columns in a single bulk query for efficient schema loading.
    func schemaDetails(schema: String) async throws -> [MySQLSchemaObjectDetail] {
        let sql = """
        SELECT
            t.table_name,
            t.table_type,
            c.column_name,
            c.data_type,
            c.is_nullable,
            c.column_key,
            c.character_maximum_length,
            c.ordinal_position
        FROM information_schema.tables t
        LEFT JOIN information_schema.columns c
          ON c.table_schema = t.table_schema
         AND c.table_name = t.table_name
        WHERE t.table_schema = ? AND t.table_type IN ('BASE TABLE', 'VIEW')
        ORDER BY t.table_name, c.ordinal_position;
        """

        let connection = try await serverConnection.metadata()
        let result = try await connection.query(sql, binds: [MySQLData(string: schema)])

        var grouped: [String: (kind: MySQLSchemaObjectKind, columns: [MySQLSchemaObjectColumnInfo])] = [:]

        for row in result.rows {
            guard
                let name = row.field("table_name")?.string,
                let tableType = row.field("table_type")?.string
            else { continue }

            let kind = MySQLSchemaObjectKind(tableType: tableType) ?? .table
            var entry = grouped[name] ?? (kind: kind, columns: [])

            if let columnName = row.field("column_name")?.string {
                let dataType = row.field("data_type")?.string ?? ""
                let nullable = row.field("is_nullable")?.string
                let columnKey = row.field("column_key")?.string
                let length = row.field("character_maximum_length")?.string.flatMap(Int.init)
                let position = row.field("ordinal_position")?.string.flatMap(Int.init) ?? 0

                entry.columns.append(MySQLSchemaObjectColumnInfo(
                    name: columnName,
                    dataType: dataType,
                    isPrimaryKey: columnKey == "PRI",
                    isNullable: (nullable ?? "YES").uppercased() != "NO",
                    maxLength: length,
                    ordinalPosition: position
                ))
            }

            grouped[name] = entry
        }

        return grouped.map { name, entry in
            MySQLSchemaObjectDetail(
                name: name,
                schema: schema,
                kind: entry.kind,
                columns: entry.columns.sorted { $0.ordinalPosition < $1.ordinalPosition }
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

public struct MySQLDatabaseInfo: Sendable, Hashable {
    public let sizeMB: Double
    public let characterSet: String?
    public let collation: String?

    public init(sizeMB: Double, characterSet: String?, collation: String?) {
        self.sizeMB = sizeMB
        self.characterSet = characterSet
        self.collation = collation
    }
}

public struct MySQLSchemaObjectColumnInfo: Sendable, Hashable {
    public let name: String
    public let dataType: String
    public let isPrimaryKey: Bool
    public let isNullable: Bool
    public let maxLength: Int?
    public let ordinalPosition: Int

    public init(
        name: String,
        dataType: String,
        isPrimaryKey: Bool,
        isNullable: Bool,
        maxLength: Int?,
        ordinalPosition: Int
    ) {
        self.name = name
        self.dataType = dataType
        self.isPrimaryKey = isPrimaryKey
        self.isNullable = isNullable
        self.maxLength = maxLength
        self.ordinalPosition = ordinalPosition
    }
}

public struct MySQLSchemaObjectDetail: Sendable, Hashable {
    public let name: String
    public let schema: String
    public let kind: MySQLSchemaObjectKind
    public let columns: [MySQLSchemaObjectColumnInfo]

    public init(
        name: String,
        schema: String,
        kind: MySQLSchemaObjectKind,
        columns: [MySQLSchemaObjectColumnInfo]
    ) {
        self.name = name
        self.schema = schema
        self.kind = kind
        self.columns = columns
    }
}
