import Foundation
import MySQLKit
import MySQLKitTesting
import Testing

/// Rows in and out: bulk DML, transactions, scripts, session settings and column types.
@Suite(.testServer)
struct DataTests {
    @Test func bulkInsertInChunksUpdateAndDelete() async throws {
        let server = try TestServer.require()
        try await server.withSchema { client, schema in
            try await client.admin.createTable(schema: schema, name: "items", columns: [
                MySQLColumnDefinition(name: "id", dataType: "INT", isNullable: false),
                MySQLColumnDefinition(name: "label", dataType: "VARCHAR(50)"),
            ], primaryKey: ["id"])
            let rows = (1...1234).map { [MySQLData(int: $0), MySQLData(string: "item \($0)")] }
            let result = try await client.bulk.insert(into: "items", schema: schema, columns: ["id", "label"], rows: rows, chunkSize: 500)
            #expect(result.insertedRowCount == 1234)
            #expect(result.chunksExecuted == 3)
            #expect(try await client.metadata.exactRowCount(schema: schema, table: "items") == 1234)

            try await client.bulk.updateRows(in: "items", schema: schema, set: ["label": .data(MySQLData(string: "renamed"))],
                                             where: ["id": .data(MySQLData(int: 7))])
            let renamed = try await client.query("SELECT label FROM `\(schema)`.items WHERE id = ?", binds: [MySQLData(int: 7)])
            #expect(renamed.rows.first?.column("label")?.string == "renamed")

            try await client.bulk.deleteRows(from: "items", schema: schema, where: ["id": .data(MySQLData(int: 7))])
            #expect(try await client.metadata.exactRowCount(schema: schema, table: "items") == 1233)
            await #expect(throws: (any Error).self) { try await client.bulk.deleteRows(from: "items", schema: schema, where: [:]) }
        }
    }

    @Test func typedInsertValues() async throws {
        let server = try TestServer.require()
        let flavor = try await server.flavor()
        try await server.withSchema { client, schema in
            try await client.admin.createTable(schema: schema, name: "typed", columns: [
                MySQLColumnDefinition(name: "doc", dataType: "JSON"),
                MySQLColumnDefinition(name: "place", dataType: "POINT"),
                MySQLColumnDefinition(name: "flags", dataType: "BIT(8)"),
                MySQLColumnDefinition(name: "note", dataType: "TEXT"),
            ])
            let inserted = try await client.bulk.insertValues(into: "typed", schema: schema, columns: ["doc", "place", "flags", "note"], rows: [
                [.json(#"{"a": [1, 2]}"#), .geometry(wkt: "POINT(1 2)"), .bits(0b1010_0101), .null],
            ])
            #expect(inserted == 1)
            let row = try #require(try await client.simpleQuery(
                "SELECT JSON_EXTRACT(doc, '$.a[1]') AS second, ST_AsText(place) AS place, flags + 0 AS flags, note FROM `\(schema)`.typed").first)
            #expect(row.column("second")?.string == "2")
            #expect(row.column("place")?.string == "POINT(1 2)")
            #expect(row.column("flags")?.int == 0b1010_0101)
            #expect(row.column("note")?.string == nil)
            _ = flavor
        }
    }

    @Test func transactionsCommitAndRollBack() async throws {
        let server = try TestServer.require()
        try await server.withSchema { client, schema in
            try await client.admin.createTable(schema: schema, name: "ledger", columns: [MySQLColumnDefinition(name: "v", dataType: "INT")])
            let other = server.client()
            defer { Task { await other.close() } }
            func visibleElsewhere() async throws -> Int {
                try await other.metadata.exactRowCount(schema: schema, table: "ledger")
            }

            try await client.transactions.begin()
            _ = try await client.simpleQuery("INSERT INTO `\(schema)`.ledger VALUES (1)")
            #expect(try await visibleElsewhere() == 0)
            try await client.transactions.rollback()
            #expect(try await client.metadata.exactRowCount(schema: schema, table: "ledger") == 0)

            let value = try await client.transactions.withTransaction {
                _ = try await client.simpleQuery("INSERT INTO `\(schema)`.ledger VALUES (2)")
                return 2
            }
            #expect(value == 2)
            #expect(try await visibleElsewhere() == 1)

            struct Boom: Error {}
            await #expect(throws: Boom.self) {
                try await client.transactions.withTransaction {
                    _ = try await client.simpleQuery("INSERT INTO `\(schema)`.ledger VALUES (3)")
                    throw Boom()
                }
            }
            #expect(try await visibleElsewhere() == 1)
        }
    }

    @Test func dedicatedSessionsAreIndependent() async throws {
        let server = try TestServer.require()
        let first = try await MySQLDedicatedSession.open(configuration: server.configuration)
        let second = try await MySQLDedicatedSession.open(configuration: server.configuration)
        _ = try await first.simpleQuery("SET @marker = 'first'")
        #expect(try await first.simpleQuery("SELECT @marker AS m").first?.column("m")?.string == "first")
        #expect(try await second.simpleQuery("SELECT @marker AS m").first?.column("m")?.string == nil)
        let bound = try await second.query("SELECT ? + 1 AS v", binds: [MySQLData(int: 41)])
        #expect(bound.rows.first?.column("v")?.int == 42)
        await first.close()
        await second.close()
    }

    @Test func scriptsWithDelimitersAndComments() async throws {
        let server = try TestServer.require()
        try await server.withSchema { client, schema in
            let script = """
            -- a comment
            CREATE TABLE t (id INT PRIMARY KEY, label VARCHAR(20));
            INSERT INTO t VALUES (1, 'semi;colon'), (2, 'it''s');
            # another comment
            DELIMITER $$
            CREATE PROCEDURE add_row(IN v INT)
            BEGIN
              INSERT INTO t VALUES (v, 'from procedure');
            END$$
            DELIMITER ;
            CALL add_row(3);
            /* block comment; with a semicolon */
            """
            let count = try await client.scripts.run(script, database: schema)
            #expect(count == 5)
            #expect(try await client.metadata.exactRowCount(schema: schema, table: "t") == 3)
            let label = try await client.simpleQuery("SELECT label FROM `\(schema)`.t WHERE id = 1").first?.column("label")?.string
            #expect(label == "semi;colon")

            let error = await #expect(throws: MySQLScriptError.self) {
                try await client.scripts.run("SELECT 1;\nSELECT * FROM no_such_table;\nSELECT 3;", database: schema)
            }
            #expect(error?.statementNumber == 2)
        }
    }

    @Test func sessionSettings() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            _ = try await client.session.setSQLMode("ANSI_QUOTES,STRICT_ALL_TABLES")
            #expect(try await client.session.sqlMode()?.contains("ANSI_QUOTES") == true)
            _ = try await client.session.setSQLMode(nil)
            #expect(try await client.session.sqlMode()?.contains("ANSI_QUOTES") == false)

            for level in MySQLTransactionIsolationLevel.allCases {
                try await client.session.setTransactionIsolationLevel(level)
                #expect(try await client.session.transactionIsolationLevel() == level)
            }
            _ = try await client.session.setSessionVariable(name: "wait_timeout", value: "1234")
            #expect(try await client.session.sessionVariables(named: ["wait_timeout"]).first?.value == "1234")
            #expect(try await client.session.currentDatabase() == nil)
        }
    }

    @Test func namedLocksAreExclusive() async throws {
        let server = try TestServer.require()
        try await server.withClient { client async throws in
            let other = server.client()
            defer { Task { await other.close() } }
            let name = TestServer.uniqueName("lock")
            #expect(try await client.session.acquireNamedLock(name).acquired)
            #expect(try await !other.session.acquireNamedLock(name, timeoutSeconds: 0).acquired)
            #expect(try await client.session.releaseNamedLock(name).acquired)
            #expect(try await other.session.acquireNamedLock(name, timeoutSeconds: 1).acquired)
        }
    }

    /// Edge values of each column type come back exactly as the server prints them.
    @Test func columnTypesRoundTrip() async throws {
        let server = try TestServer.require()
        try await server.withSchema { client, schema in
            try await client.admin.createTable(schema: schema, name: "types", columns: [
                MySQLColumnDefinition(name: "big_unsigned", dataType: "BIGINT UNSIGNED"),
                MySQLColumnDefinition(name: "big_signed", dataType: "BIGINT"),
                MySQLColumnDefinition(name: "tiny", dataType: "TINYINT"),
                MySQLColumnDefinition(name: "dec", dataType: "DECIMAL(65,30)"),
                MySQLColumnDefinition(name: "dbl", dataType: "DOUBLE"),
                MySQLColumnDefinition(name: "d", dataType: "DATE"),
                MySQLColumnDefinition(name: "dt", dataType: "DATETIME(6)"),
                MySQLColumnDefinition(name: "t", dataType: "TIME"),
                MySQLColumnDefinition(name: "y", dataType: "YEAR"),
                MySQLColumnDefinition(name: "txt", dataType: "LONGTEXT"),
                MySQLColumnDefinition(name: "bin", dataType: "VARBINARY(16)"),
                MySQLColumnDefinition(name: "e", dataType: "ENUM('small','large')"),
                MySQLColumnDefinition(name: "s", dataType: "SET('a','b','c')"),
            ])
            _ = try await client.simpleQuery("""
                INSERT INTO `\(schema)`.types VALUES (18446744073709551615, -9223372036854775808, -128,
                  '12345678901234567890123456789012345.123456789012345678901234567890', 1.5e300,
                  '9999-12-31', '2024-02-29 23:59:59.123456', '-838:59:59', 2155,
                  REPEAT('x', 100000), 0x00FF10, 'large', 'a,c')
                """)
            let text = try #require(try await client.simpleQuery("SELECT * FROM `\(schema)`.types").first)
            #expect(text.column("big_unsigned")?.string == "18446744073709551615")
            #expect(text.column("big_signed")?.string == "-9223372036854775808")
            #expect(text.column("tiny")?.int == -128)
            #expect(text.column("dec")?.string == "12345678901234567890123456789012345.123456789012345678901234567890")
            #expect(text.column("d")?.string == "9999-12-31")
            #expect(text.column("dt")?.string == "2024-02-29 23:59:59.123456")
            #expect(text.column("t")?.string == "-838:59:59")
            #expect(text.column("y")?.string == "2155")
            #expect(text.column("txt")?.string?.count == 100_000)
            #expect(text.column("bin")?.buffer?.readableBytesView.map { $0 } == [0x00, 0xFF, 0x10])
            #expect(text.column("e")?.string == "large")
            #expect(text.column("s")?.string == "a,c")

            // The same row through the binary protocol (a statement with binds).
            let binary = try #require(try await client.query("SELECT * FROM `\(schema)`.types WHERE tiny = ?", binds: [MySQLData(int: -128)]).rows.first)
            #expect(binary.column("big_signed")?.int == Int.min)
            withKnownIssue("mysql-nio's MySQLData.string is nil for binary DECIMAL and temporal values") {
                #expect(binary.column("dec")?.string == "12345678901234567890123456789012345.123456789012345678901234567890")
            }
            #expect(binary.column("dbl")?.double == 1.5e300)
            #expect(binary.column("e")?.string == "large")
        }
    }

    @Test func largeValuesInBothDirections() async throws {
        let server = try TestServer.require()
        try await server.withSchema { client, schema in
            try await client.admin.createTable(schema: schema, name: "blobs", columns: [MySQLColumnDefinition(name: "b", dataType: "LONGBLOB")])
            let bytes = (0..<2_000_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }
            var buffer = ByteBufferAllocator().buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            _ = try await client.query("INSERT INTO `\(schema)`.blobs VALUES (?)", binds: [MySQLData(type: .blob, buffer: buffer)])
            let back = try await client.simpleQuery("SELECT b, LENGTH(b) AS n FROM `\(schema)`.blobs").first
            #expect(back?.column("n")?.int == bytes.count)
            #expect(back?.column("b")?.buffer?.readableBytesView.elementsEqual(bytes) == true)
        }
    }
}
