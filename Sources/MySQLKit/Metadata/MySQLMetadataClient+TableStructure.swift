import Foundation
import MySQLWire

public extension MySQLMetadataClient {
    func tableStructure(for table: String, schema: String? = nil) async throws -> MySQLTableStructure {
        guard let schemaName = try await resolvedSchemaName(schema) else {
            return MySQLTableStructure(
                columns: [],
                primaryKey: nil,
                indexes: [],
                foreignKeys: [],
                dependencies: []
            )
        }

        async let columns = listColumns(in: table, schema: schemaName)
        async let primaryKey = fetchPrimaryKey(schema: schemaName, table: table)
        async let indexes = fetchIndexes(schema: schemaName, table: table)
        async let foreignKeys = fetchForeignKeys(schema: schemaName, table: table)
        async let dependencies = fetchDependencies(schema: schemaName, table: table)

        return try await MySQLTableStructure(
            columns: columns,
            primaryKey: primaryKey,
            indexes: indexes,
            foreignKeys: foreignKeys,
            dependencies: dependencies
        )
    }

    private func fetchPrimaryKey(schema: String, table: String) async throws -> MySQLPrimaryKeyInfo? {
        let sql = """
        SELECT k.constraint_name, k.column_name
        FROM information_schema.table_constraints t
        JOIN information_schema.key_column_usage k
          ON k.constraint_name = t.constraint_name
         AND k.table_schema = t.table_schema
        WHERE t.table_schema = ?
          AND t.table_name = ?
          AND t.constraint_type = 'PRIMARY KEY'
        ORDER BY k.ordinal_position;
        """

        let connection = try await serverConnection.metadata()
        let result = try await connection.query(
            sql,
            binds: [MySQLData(string: schema), MySQLData(string: table)]
        )
        guard let firstRow = result.rows.first else {
            return nil
        }

        let name = firstRow.field("constraint_name")?.string ?? "PRIMARY"
        let columns = result.rows.compactMap { $0.field("column_name")?.string }
        return MySQLPrimaryKeyInfo(name: name, columns: columns)
    }

    private func fetchIndexes(schema: String, table: String) async throws -> [MySQLIndexInfo] {
        let sql = """
        SELECT
            index_name,
            non_unique,
            seq_in_index,
            column_name,
            collation,
            index_type
        FROM information_schema.statistics
        WHERE table_schema = ? AND table_name = ?
        ORDER BY index_name, seq_in_index;
        """

        let connection = try await serverConnection.metadata()
        let result = try await connection.query(
            sql,
            binds: [MySQLData(string: schema), MySQLData(string: table)]
        )

        var grouped: [String: (isUnique: Bool, columns: [MySQLIndexColumnInfo])] = [:]
        var indexTypes: [String: String] = [:]
        for row in result.rows {
            guard
                let name = row.field("index_name")?.string,
                let columnName = row.field("column_name")?.string
            else {
                continue
            }

            let isUnique = row.field("non_unique")?.string == "0"
            let position = row.field("seq_in_index")?.string.flatMap(Int.init) ?? 0
            let sortOrder: MySQLIndexColumnInfo.SortOrder =
                row.field("collation")?.string == "D" ? .descending : .ascending
            let indexType = row.field("index_type")?.string

            var entry = grouped[name] ?? (true, [])
            entry.isUnique = entry.isUnique && isUnique
            entry.columns.append(MySQLIndexColumnInfo(name: columnName, position: position, sortOrder: sortOrder))
            grouped[name] = entry

            if let indexType {
                indexTypes[name] = indexType
            }
        }

        return grouped.compactMap { name, value in
            guard name.uppercased() != "PRIMARY" else {
                return nil
            }
            return MySQLIndexInfo(
                name: name,
                columns: value.columns.sorted { $0.position < $1.position },
                isUnique: value.isUnique,
                indexType: indexTypes[name]
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func fetchForeignKeys(schema: String, table: String) async throws -> [MySQLForeignKeyInfo] {
        let sql = """
        SELECT
            rc.constraint_name,
            kcu.column_name,
            kcu.referenced_table_schema,
            kcu.referenced_table_name,
            kcu.referenced_column_name,
            rc.update_rule,
            rc.delete_rule,
            kcu.ordinal_position
        FROM information_schema.referential_constraints rc
        JOIN information_schema.key_column_usage kcu
          ON rc.constraint_name = kcu.constraint_name
         AND rc.constraint_schema = kcu.constraint_schema
        WHERE rc.constraint_schema = ?
          AND rc.table_name = ?
        ORDER BY rc.constraint_name, kcu.ordinal_position;
        """

        let connection = try await serverConnection.metadata()
        let result = try await connection.query(
            sql,
            binds: [MySQLData(string: schema), MySQLData(string: table)]
        )

        var grouped: [String: (columns: [String], referencedSchema: String, referencedTable: String, referencedColumns: [String], onUpdate: String?, onDelete: String?)] = [:]
        for row in result.rows {
            guard let name = row.field("constraint_name")?.string else {
                continue
            }

            let column = row.field("column_name")?.string
            let referencedSchema = row.field("referenced_table_schema")?.string ?? schema
            let referencedTable = row.field("referenced_table_name")?.string ?? ""
            let referencedColumn = row.field("referenced_column_name")?.string
            let onUpdate = row.field("update_rule")?.string
            let onDelete = row.field("delete_rule")?.string

            var entry = grouped[name] ?? ([], referencedSchema, referencedTable, [], onUpdate, onDelete)
            if let column {
                entry.columns.append(column)
            }
            if let referencedColumn {
                entry.referencedColumns.append(referencedColumn)
            }
            entry.onUpdate = onUpdate
            entry.onDelete = onDelete
            grouped[name] = entry
        }

        return grouped.map { name, value in
            MySQLForeignKeyInfo(
                name: name,
                columns: value.columns,
                referencedSchema: value.referencedSchema,
                referencedTable: value.referencedTable,
                referencedColumns: value.referencedColumns,
                onUpdate: value.onUpdate,
                onDelete: value.onDelete
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func fetchDependencies(schema: String, table: String) async throws -> [MySQLDependencyInfo] {
        let sql = """
        SELECT
            kcu.constraint_name,
            kcu.column_name,
            kcu.referenced_table_name,
            kcu.referenced_column_name,
            rc.update_rule,
            rc.delete_rule
        FROM information_schema.key_column_usage kcu
        JOIN information_schema.referential_constraints rc
          ON rc.constraint_name = kcu.constraint_name
         AND rc.constraint_schema = kcu.constraint_schema
        WHERE kcu.referenced_table_schema = ?
          AND kcu.referenced_table_name = ?
        ORDER BY kcu.constraint_name, kcu.ordinal_position;
        """

        let connection = try await serverConnection.metadata()
        let result = try await connection.query(
            sql,
            binds: [MySQLData(string: schema), MySQLData(string: table)]
        )

        var grouped: [String: MySQLDependencyInfo] = [:]
        for row in result.rows {
            guard let name = row.field("constraint_name")?.string else {
                continue
            }

            let baseColumn = row.field("column_name")?.string
            let referencedTable = row.field("referenced_table_name")?.string ?? ""
            let referencedColumn = row.field("referenced_column_name")?.string
            let onUpdate = row.field("update_rule")?.string
            let onDelete = row.field("delete_rule")?.string

            var dependency = grouped[name] ?? MySQLDependencyInfo(
                name: name,
                baseColumns: [],
                referencedTable: referencedTable,
                referencedColumns: [],
                onUpdate: onUpdate,
                onDelete: onDelete
            )
            if let baseColumn {
                dependency = MySQLDependencyInfo(
                    name: dependency.name,
                    baseColumns: dependency.baseColumns + [baseColumn],
                    referencedTable: dependency.referencedTable,
                    referencedColumns: dependency.referencedColumns,
                    onUpdate: onUpdate,
                    onDelete: onDelete
                )
            }
            if let referencedColumn {
                dependency = MySQLDependencyInfo(
                    name: dependency.name,
                    baseColumns: dependency.baseColumns,
                    referencedTable: dependency.referencedTable,
                    referencedColumns: dependency.referencedColumns + [referencedColumn],
                    onUpdate: onUpdate,
                    onDelete: onDelete
                )
            }
            grouped[name] = dependency
        }

        return grouped.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
