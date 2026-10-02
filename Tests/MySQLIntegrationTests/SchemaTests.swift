import Foundation
import MySQLKit
import MySQLKitTesting
import Testing

/// Databases, tables, columns, indexes and constraints: created through the typed APIs and read
/// back through the metadata client.
@Suite(.testServer)
struct SchemaTests {
    static let customerColumns = [
        MySQLColumnDefinition(name: "id", dataType: "INT UNSIGNED", isNullable: false, isAutoIncrement: true),
        MySQLColumnDefinition(name: "email", dataType: "VARCHAR(190)", isNullable: false, comment: "login"),
        MySQLColumnDefinition(name: "name", dataType: "VARCHAR(100)", characterSet: "utf8mb4", collation: "utf8mb4_bin"),
        MySQLColumnDefinition(name: "credit", dataType: "DECIMAL(10,2)", isNullable: false, defaultValue: .number("0.00")),
        MySQLColumnDefinition(name: "created_at", dataType: "TIMESTAMP", isNullable: false, defaultValue: .currentTimestamp()),
        MySQLColumnDefinition(name: "email_domain", dataType: "VARCHAR(190)",
                              generated: MySQLGeneratedColumn(expression: "SUBSTRING_INDEX(`email`, '@', -1)", isStored: true)),
    ]

    @Test func createsAndListsDatabases() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            let name = TestServer.uniqueName("db")
            try await client.admin.createDatabase(name: name, characterSet: "utf8mb4", collation: "utf8mb4_unicode_ci")
            try await client.admin.createDatabase(name: name, ifNotExists: true)
            #expect(try await client.metadata.listDatabases().contains(name))
            #expect(try await !client.metadata.listDatabases().contains("information_schema"))
            #expect(try await client.metadata.listDatabases(includeSystem: true).contains("information_schema"))
            let info = try await client.metadata.databaseInfo(schema: name)
            #expect(info.characterSet == "utf8mb4")
            #expect(info.collation == "utf8mb4_unicode_ci")
            try await client.admin.dropDatabase(name: name)
            #expect(try await !client.metadata.listDatabases().contains(name))
        }
    }

    @Test func tableColumnsAndOptionsRoundTrip() async throws {
        let server = try TestServer.require()
        try await server.withSchema { client, schema in
            try await client.admin.createTable(schema: schema, name: "customers", columns: Self.customerColumns, primaryKey: ["id"],
                                               options: MySQLTableOptions(engine: "InnoDB", characterSet: "utf8mb4",
                                                                          comment: "people who buy things"))
            let tables = try await client.metadata.listTables(in: schema)
            #expect(tables.map(\.name) == ["customers"])
            #expect(tables.first?.kind == .table)

            let columns = try await client.metadata.listColumns(in: "customers", schema: schema)
            #expect(columns.map(\.name) == ["id", "email", "name", "credit", "created_at", "email_domain"])
            let id = try #require(columns.first { $0.name == "id" })
            #expect(id.isPrimaryKey && id.isAutoIncrement && !id.isNullable)
            #expect(id.fullDataType.lowercased().contains("unsigned"))
            let email = try #require(columns.first { $0.name == "email" })
            #expect(email.maxLength == 190)
            #expect(email.comment == "login")
            let name = try #require(columns.first { $0.name == "name" })
            #expect(name.isNullable)
            #expect(name.collation == "utf8mb4_bin")
            let credit = try #require(columns.first { $0.name == "credit" })
            #expect(credit.defaultValue == "0.00")
            let domain = try #require(columns.first { $0.name == "email_domain" })
            #expect(domain.generationExpression?.contains("email") == true)

            let options = try #require(try await client.metadata.tableOptions(for: "customers", schema: schema))
            #expect(options.engine == "InnoDB")
            #expect(options.comment == "people who buy things")

            let definition = try await client.metadata.objectDefinition(named: "customers", schema: schema, kind: .table)
            #expect(definition.contains("CREATE TABLE"))
            #expect(definition.contains("email_domain"))
        }
    }

    @Test func addRenameAndDropTables() async throws {
        let server = try TestServer.require()
        try await server.withSchema { client, schema in
            try await client.admin.createTable(schema: schema, name: "t", columns: [MySQLColumnDefinition(name: "a", dataType: "INT")])
            try await client.admin.createTable(schema: schema, name: "t", columns: [MySQLColumnDefinition(name: "a", dataType: "INT")],
                                               ifNotExists: true)
            try await client.admin.addColumn(schema: schema, table: "t", column: MySQLColumnDefinition(name: "c", dataType: "TEXT"))
            try await client.admin.addColumn(schema: schema, table: "t", column: MySQLColumnDefinition(name: "b", dataType: "INT"), after: "a")
            #expect(try await client.metadata.listColumns(in: "t", schema: schema).map(\.name) == ["a", "b", "c"])
            try await client.admin.renameTable(schema: schema, from: "t", to: "renamed")
            #expect(try await client.metadata.listTables(in: schema).map(\.name) == ["renamed"])
            try await client.admin.dropTable(schema: schema, name: "renamed")
            try await client.admin.dropTable(schema: schema, name: "renamed")  // IF EXISTS
            #expect(try await client.metadata.listTables(in: schema).isEmpty)
        }
    }

    @Test func namesWithBackticksQuotesAndUnicode() async throws {
        let server = try TestServer.require()
        try await server.withSchema { client, schema in
            // Identifiers are utf8mb3: accents yes, emoji no.
            let table = "we`ird 'name' üß"
            try await client.admin.createTable(schema: schema, name: table,
                                               columns: [MySQLColumnDefinition(name: "col`umn", dataType: "INT")])
            #expect(try await client.metadata.listTables(in: schema).map(\.name) == [table])
            #expect(try await client.metadata.listColumns(in: table, schema: schema).map(\.name) == ["col`umn"])
            _ = try await client.bulk.insert(into: table, schema: schema, columns: ["col`umn"], rows: [[MySQLData(int: 5)]])
            #expect(try await client.metadata.exactRowCount(schema: schema, table: table) == 1)
        }
    }

    @Test func indexesAndForeignKeys() async throws {
        let server = try TestServer.require()
        let flavor = try await server.flavor()
        try await server.withSchema { client, schema in
            try await client.admin.createTable(schema: schema, name: "customers", columns: Self.customerColumns, primaryKey: ["id"])
            try await client.admin.createTable(schema: schema, name: "orders", columns: [
                MySQLColumnDefinition(name: "id", dataType: "INT UNSIGNED", isNullable: false, isAutoIncrement: true),
                MySQLColumnDefinition(name: "customer_id", dataType: "INT UNSIGNED"),
                MySQLColumnDefinition(name: "total", dataType: "DECIMAL(10,2)"),
                MySQLColumnDefinition(name: "notes", dataType: "TEXT"),
            ], primaryKey: ["id"])
            try await client.indexes.createIndex(schema: schema, table: "customers", name: "ux_email", columns: ["email"], kind: .unique)
            try await client.indexes.createIndex(schema: schema, table: "customers", name: "ix_name_credit",
                                                 columns: [MySQLIndexColumn("name", prefixLength: 20), MySQLIndexColumn("credit", isDescending: true)],
                                                 comment: "lookup")
            try await client.indexes.createIndex(schema: schema, table: "orders", name: "ft_notes", columns: ["notes"], kind: .fulltext)
            try await client.constraints.addForeignKey(schema: schema, table: "orders", name: "fk_orders_customer", columns: ["customer_id"],
                                                       referencedTable: "customers", referencedColumns: ["id"],
                                                       onDelete: .cascade, onUpdate: .restrict)
            try await client.constraints.addCheck(schema: schema, table: "orders", name: "ck_total", expression: "`total` >= 0")
            try await client.constraints.addUnique(schema: schema, table: "orders", name: "uq_customer_total", columns: ["customer_id", "total"])

            let customers = try await client.metadata.tableStructure(for: "customers", schema: schema)
            #expect(customers.primaryKey?.columns == ["id"])
            let unique = try #require(customers.indexes.first { $0.name == "ux_email" })
            #expect(unique.isUnique)
            let composite = try #require(customers.indexes.first { $0.name == "ix_name_credit" })
            #expect(composite.columns.map(\.name) == ["name", "credit"])
            if flavor.isMySQL || flavor.atLeast(10, 8) {
                #expect(composite.columns.last?.sortOrder == .descending)
            }

            let orders = try await client.metadata.tableStructure(for: "orders", schema: schema)
            let foreignKey = try #require(orders.foreignKeys.first)
            #expect(foreignKey.name == "fk_orders_customer")
            #expect(foreignKey.columns == ["customer_id"])
            #expect(foreignKey.referencedTable == "customers")
            #expect(foreignKey.referencedColumns == ["id"])
            #expect(foreignKey.onDelete == "CASCADE")
            #expect(orders.indexes.contains { $0.name == "ft_notes" && $0.indexType == "FULLTEXT" })
            #expect(orders.indexes.contains { $0.name == "uq_customer_total" && $0.isUnique })

            // The CHECK constraint is enforced.
            _ = try await client.bulk.insert(into: "customers", schema: schema, columns: ["email"], rows: [[MySQLData(string: "a@b.c")]])
            await #expect(throws: (any Error).self) {
                _ = try await client.bulk.insert(into: "orders", schema: schema, columns: ["customer_id", "total"],
                                                 rows: [[MySQLData(int: 1), MySQLData(double: -1)]])
            }

            try await client.indexes.dropIndex(schema: schema, name: "ix_name_credit")
            try await client.indexes.dropIndex(schema: schema, table: "customers", name: "ux_email")
            let after = try await client.metadata.tableStructure(for: "customers", schema: schema)
            #expect(!after.indexes.contains { $0.name == "ix_name_credit" || $0.name == "ux_email" })
            await #expect(throws: MySQLIndexError.self) { try await client.indexes.dropIndex(schema: schema, name: "no_such_index") }
        }
    }

    @Test func invisibleIndexOnMySQL() async throws {
        let server = try TestServer.require()
        guard try await server.flavor().isMySQL else { return }  // MariaDB says IGNORED, not INVISIBLE
        try await server.withSchema { client, schema in
            try await client.admin.createTable(schema: schema, name: "t", columns: [MySQLColumnDefinition(name: "a", dataType: "INT")])
            try await client.indexes.createIndex(schema: schema, table: "t", name: "ix_a", columns: ["a"], isInvisible: true)
            let rows = try await client.query("SELECT IS_VISIBLE AS v FROM information_schema.statistics WHERE TABLE_SCHEMA = ? AND INDEX_NAME = 'ix_a'",
                                              binds: [MySQLData(string: schema)]).rows
            #expect(rows.first?.column("v")?.string == "NO")
        }
    }

    @Test func partitionedTables() async throws {
        let server = try TestServer.require()
        try await server.withSchema { client, schema in
            try await client.admin.createTable(schema: schema, name: "sales", columns: [
                MySQLColumnDefinition(name: "id", dataType: "INT", isNullable: false),
                MySQLColumnDefinition(name: "y", dataType: "INT", isNullable: false),
            ], primaryKey: ["id", "y"], options: MySQLTableOptions(partitioning: .range(expression: "`y`", partitions: [
                (name: "p2020", lessThan: "2021"), (name: "p2021", lessThan: "2022"), (name: "pmax", lessThan: nil),
            ])))
            try await client.admin.createTable(schema: schema, name: "hashed", columns: [
                MySQLColumnDefinition(name: "id", dataType: "INT", isNullable: false),
            ], primaryKey: ["id"], options: MySQLTableOptions(partitioning: .hash(expression: "`id`", count: 4)))
            #expect(try await client.metadata.listPartitions(schema: schema, table: "sales").map(\.name) == ["p2020", "p2021", "pmax"])
            #expect(try await client.metadata.listPartitions(schema: schema, table: "hashed").count == 4)
        }
    }

    @Test func searchAndSchemaDetails() async throws {
        let server = try TestServer.require()
        try await server.withSchema { client, schema in
            try await client.admin.createTable(schema: schema, name: "customers", columns: Self.customerColumns, primaryKey: ["id"])
            try await client.views.createView(schema: schema, name: "customer_emails", definitionSQL: "SELECT email FROM `\(schema)`.customers")
            let found = try await client.metadata.searchObjects(matching: "customer%", schema: schema)
            #expect(try await client.metadata.searchObjects(matching: "customer", schema: schema).isEmpty)
            #expect(Set(found.map(\.name)).isSuperset(of: ["customers", "customer_emails"]))
            let objects = try await client.metadata.listTablesAndViews(in: schema)
            #expect(Set(objects.map(\.name)) == ["customers", "customer_emails"])
            #expect(objects.first { $0.name == "customer_emails" }?.kind == .view)
            let details = try await client.metadata.schemaDetails(schema: schema)
            let customers = try #require(details.first { $0.name == "customers" })
            #expect(customers.columns.first?.isPrimaryKey == true)
        }
    }

    @Test func readOnlySchemaOnMySQL() async throws {
        let server = try TestServer.require()
        let flavor = try await server.flavor()
        guard flavor.isMySQL, flavor.atLeast(8, 0, 22) else { return }
        try await server.withSchema { client, schema in
            try await client.admin.createTable(schema: schema, name: "t", columns: [MySQLColumnDefinition(name: "a", dataType: "INT")])
            try await client.admin.setSchemaReadOnly(name: schema, readOnly: true)
            #expect(try await client.metadata.isSchemaReadOnly(name: schema))
            await #expect(throws: (any Error).self) {
                _ = try await client.bulk.insert(into: "t", schema: schema, columns: ["a"], rows: [[MySQLData(int: 1)]])
            }
            try await client.admin.setSchemaReadOnly(name: schema, readOnly: false)
            #expect(try await !client.metadata.isSchemaReadOnly(name: schema))
        }
    }

    @Test func sequencesAndSystemVersioningOnMariaDB() async throws {
        let server = try TestServer.require()
        guard try await server.flavor().isMariaDB else { return }
        try await server.withSchema { client, schema in
            try await client.admin.createSequence(schema: schema, name: "invoice_numbers", start: 1000, increment: 10, cycle: false)
            #expect(try await client.metadata.listSequences(schema: schema) == ["invoice_numbers"])
            let next = try await client.simpleQuery("SELECT NEXTVAL(`\(schema)`.invoice_numbers) AS n")
            #expect(next.first?.column("n")?.int == 1000)

            try await client.admin.createTable(schema: schema, name: "prices", columns: [
                MySQLColumnDefinition(name: "id", dataType: "INT", isNullable: false),
                MySQLColumnDefinition(name: "price", dataType: "DECIMAL(8,2)"),
            ], primaryKey: ["id"], options: MySQLTableOptions(systemVersioning: true))
            #expect(try await client.metadata.listSystemVersionedTables(schema: schema) == ["prices"])
        }
    }
}
