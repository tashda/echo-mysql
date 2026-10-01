import MySQLWire

public extension MySQLAdminClient {
    func createDatabase(name: String, characterSet: String? = nil, collation: String? = nil, ifNotExists: Bool = false) async throws {
        try await run(MySQLTableSQL.createDatabase(name: name, characterSet: characterSet, collation: collation, ifNotExists: ifNotExists))
    }

    func dropDatabase(name: String, ifExists: Bool = true) async throws {
        try await run("DROP DATABASE \(ifExists ? "IF EXISTS " : "")\(MySQLTableSQL.identifier(name))")
    }

    /// Creates a table from typed columns. `primaryKey` names the key's columns.
    func createTable(schema: String, name: String, columns: [MySQLColumnDefinition], primaryKey: [String] = [],
                     options: MySQLTableOptions = .init(), ifNotExists: Bool = false) async throws {
        try await run(MySQLTableSQL.createTable(schema: schema, name: name, columns: columns, primaryKey: primaryKey,
                                                options: options, ifNotExists: ifNotExists))
    }

    /// A sequence (MariaDB 10.3+; MySQL has none).
    func createSequence(schema: String, name: String, start: Int = 1, increment: Int = 1, minValue: Int? = nil,
                        maxValue: Int? = nil, cache: Int? = nil, cycle: Bool = false) async throws {
        try await run(MySQLTableSQL.createSequence(schema: schema, name: name, start: start, increment: increment,
                                                   minValue: minValue, maxValue: maxValue, cache: cache, cycle: cycle))
    }

    func addColumn(schema: String, table: String, column: MySQLColumnDefinition, after: String? = nil) async throws {
        var sql = "ALTER TABLE \(MySQLTableSQL.identifier(schema)).\(MySQLTableSQL.identifier(table)) ADD COLUMN \(MySQLTableSQL.column(column))"
        if let after { sql += " AFTER \(MySQLTableSQL.identifier(after))" }
        try await run(sql)
    }

    private func run(_ sql: String) async throws {
        let connection = try await serverConnection.primary()
        _ = try await connection.simpleQuery(sql)
    }
}

public extension MySQLIndexClient {
    func createIndex(schema: String, table: String, name: String, columns: [MySQLIndexColumn], kind: MySQLIndexKind = .standard,
                     isInvisible: Bool = false, comment: String? = nil) async throws {
        let connection = try await serverConnection.primary()
        _ = try await connection.simpleQuery(MySQLTableSQL.createIndex(schema: schema, table: table, name: name, columns: columns,
                                                                       kind: kind, isInvisible: isInvisible, comment: comment))
    }
}

public extension MySQLConstraintClient {
    func addForeignKey(schema: String, table: String, name: String, columns: [String], referencedSchema: String? = nil,
                       referencedTable: String, referencedColumns: [String], onDelete: MySQLReferentialAction? = nil,
                       onUpdate: MySQLReferentialAction? = nil) async throws {
        try await run(MySQLTableSQL.addForeignKey(schema: schema, table: table, name: name, columns: columns,
                                                  referencedSchema: referencedSchema ?? schema, referencedTable: referencedTable,
                                                  referencedColumns: referencedColumns, onDelete: onDelete, onUpdate: onUpdate))
    }

    /// A CHECK constraint (MySQL 8.0.16+; MariaDB 10.2+). `isEnforced: false` is MySQL only.
    func addCheck(schema: String, table: String, name: String, expression: String, isEnforced: Bool = true) async throws {
        try await run("ALTER TABLE \(MySQLTableSQL.identifier(schema)).\(MySQLTableSQL.identifier(table)) ADD CONSTRAINT "
            + "\(MySQLTableSQL.identifier(name)) CHECK (\(expression))\(isEnforced ? "" : " NOT ENFORCED")")
    }

    func addUnique(schema: String, table: String, name: String, columns: [String]) async throws {
        try await run("ALTER TABLE \(MySQLTableSQL.identifier(schema)).\(MySQLTableSQL.identifier(table)) ADD CONSTRAINT "
            + "\(MySQLTableSQL.identifier(name)) UNIQUE (\(columns.map(MySQLTableSQL.identifier).joined(separator: ", ")))")
    }

    private func run(_ sql: String) async throws {
        let connection = try await serverConnection.primary()
        _ = try await connection.simpleQuery(sql)
    }
}

public extension MySQLBulkOperationClient {
    /// Inserts rows whose values may need a typed conversion (geometry, JSON, vector) around the
    /// bound parameter. Returns how many rows were sent.
    @discardableResult
    func insertValues(into table: String, schema: String, columns: [String], rows: [[MySQLInsertValue]]) async throws -> Int {
        guard !rows.isEmpty else { return 0 }
        let connection = try await serverConnection.primary()
        for row in rows {
            _ = try await connection.query(MySQLTableSQL.insert(schema: schema, table: table, columns: columns, row: row), binds: row.map(\.bind))
        }
        return rows.count
    }
}

/// The statements behind the table APIs, separate so they can be tested without a server.
enum MySQLTableSQL {
    static func identifier(_ name: String) -> String { "`" + name.replacingOccurrences(of: "`", with: "``") + "`" }
    static func literal(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "''") + "'"
    }

    static func createDatabase(name: String, characterSet: String?, collation: String?, ifNotExists: Bool) -> String {
        var sql = "CREATE DATABASE \(ifNotExists ? "IF NOT EXISTS " : "")\(identifier(name))"
        if let characterSet { sql += " CHARACTER SET \(characterSet)" }
        if let collation { sql += " COLLATE \(collation)" }
        return sql
    }

    static func column(_ column: MySQLColumnDefinition) -> String {
        var parts = [identifier(column.name), column.dataType]
        if let characterSet = column.characterSet { parts.append("CHARACTER SET \(characterSet)") }
        if let collation = column.collation { parts.append("COLLATE \(collation)") }
        if let generated = column.generated {
            parts.append("GENERATED ALWAYS AS (\(generated.expression)) \(generated.isStored ? "STORED" : "VIRTUAL")")
        }
        if !column.isNullable { parts.append("NOT NULL") } else if column.generated == nil { parts.append("NULL") }
        if let srid = column.srid { parts.append("SRID \(srid)") }
        if let value = column.defaultValue {
            switch value {
            case .null: parts.append("DEFAULT NULL")
            case .string(let text): parts.append("DEFAULT \(literal(text))")
            case .number(let number): parts.append("DEFAULT \(number)")
            case .currentTimestamp(let precision): parts.append("DEFAULT CURRENT_TIMESTAMP\(precision.map { "(\($0))" } ?? "")")
            case .expression(let expression): parts.append("DEFAULT (\(expression))")
            }
        }
        if column.isAutoIncrement { parts.append("AUTO_INCREMENT") }
        if column.isInvisible { parts.append("INVISIBLE") }
        if let comment = column.comment { parts.append("COMMENT \(literal(comment))") }
        return parts.joined(separator: " ")
    }

    static func createTable(schema: String, name: String, columns: [MySQLColumnDefinition], primaryKey: [String],
                            options: MySQLTableOptions, ifNotExists: Bool) -> String {
        var elements = columns.map(column)
        if !primaryKey.isEmpty { elements.append("PRIMARY KEY (\(primaryKey.map(identifier).joined(separator: ", ")))") }
        var sql = "CREATE TABLE \(ifNotExists ? "IF NOT EXISTS " : "")\(identifier(schema)).\(identifier(name)) (\(elements.joined(separator: ", ")))"
        if let engine = options.engine { sql += " ENGINE=\(engine)" }
        if let characterSet = options.characterSet { sql += " DEFAULT CHARSET=\(characterSet)" }
        if let collation = options.collation { sql += " COLLATE=\(collation)" }
        if let rowFormat = options.rowFormat { sql += " ROW_FORMAT=\(rowFormat)" }
        if let comment = options.comment { sql += " COMMENT=\(literal(comment))" }
        if options.systemVersioning { sql += " WITH SYSTEM VERSIONING" }
        if let partitioning = options.partitioning { sql += " " + partitioning.sql }
        return sql
    }

    static func createIndex(schema: String, table: String, name: String, columns: [MySQLIndexColumn], kind: MySQLIndexKind,
                            isInvisible: Bool, comment: String?) -> String {
        let list = columns.map { column in
            identifier(column.name) + (column.prefixLength.map { "(\($0))" } ?? "") + (column.isDescending ? " DESC" : "")
        }.joined(separator: ", ")
        var sql = "CREATE \(kind.rawValue)INDEX \(identifier(name)) ON \(identifier(schema)).\(identifier(table)) (\(list))"
        if let comment { sql += " COMMENT \(literal(comment))" }
        if isInvisible { sql += " INVISIBLE" }
        return sql
    }

    static func addForeignKey(schema: String, table: String, name: String, columns: [String], referencedSchema: String,
                              referencedTable: String, referencedColumns: [String], onDelete: MySQLReferentialAction?,
                              onUpdate: MySQLReferentialAction?) -> String {
        var sql = "ALTER TABLE \(identifier(schema)).\(identifier(table)) ADD CONSTRAINT \(identifier(name)) FOREIGN KEY "
            + "(\(columns.map(identifier).joined(separator: ", "))) REFERENCES \(identifier(referencedSchema)).\(identifier(referencedTable)) "
            + "(\(referencedColumns.map(identifier).joined(separator: ", ")))"
        if let onDelete { sql += " ON DELETE \(onDelete.rawValue)" }
        if let onUpdate { sql += " ON UPDATE \(onUpdate.rawValue)" }
        return sql
    }

    static func createSequence(schema: String, name: String, start: Int, increment: Int, minValue: Int?, maxValue: Int?,
                               cache: Int?, cycle: Bool) -> String {
        var sql = "CREATE SEQUENCE \(identifier(schema)).\(identifier(name)) START WITH \(start) INCREMENT BY \(increment)"
        sql += minValue.map { " MINVALUE \($0)" } ?? " NO MINVALUE"
        sql += maxValue.map { " MAXVALUE \($0)" } ?? " NO MAXVALUE"
        if let cache { sql += " CACHE \(cache)" }
        sql += cycle ? " CYCLE" : " NOCYCLE"
        return sql
    }

    static func insert(schema: String, table: String, columns: [String], row: [MySQLInsertValue]) -> String {
        "INSERT INTO \(identifier(schema)).\(identifier(table)) (\(columns.map(identifier).joined(separator: ", "))) VALUES "
            + "(\(row.map(\.placeholder).joined(separator: ", ")))"
    }
}
