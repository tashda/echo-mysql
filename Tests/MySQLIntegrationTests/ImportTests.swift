import Foundation
import MySQLKit
import MySQLKitTesting
import Testing

/// `MySQLClient.importRows`: LOAD DATA LOCAL when the server allows it (decision D17), INSERTs
/// otherwise; every value arrives as sent, and a refused row leaves the table as it was.
@Suite(.testServer, .serialized)
struct ImportTests {
    static let awkward: [[String?]] = [
        ["1", "plain"], ["2", "back\\slash"], ["3", "tab\there"], ["4", "line\nbreak"], ["5", "cr\rhere"],
        ["6", "quote ' and \" and `"], ["7", "é😀"], ["8", nil], ["9", "\\N"], ["10", ""], ["11", "nul\u{0}byte"],
    ]

    /// Runs `body` with the server's `local_infile` set to `on`, and puts it back afterwards.
    private func withLocalInfile(_ on: Bool, _ body: () async throws -> Void) async throws {
        let server = try TestServer.require()
        let before = try await server.withClient { try await $0.simpleQuery("SELECT @@GLOBAL.local_infile AS v").first?.column("v")?.int ?? 0 }
        try await server.withClient { _ = try await $0.simpleQuery("SET GLOBAL local_infile = \(on ? 1 : 0)") }
        do {
            try await body()
        } catch {
            try? await server.withClient { _ = try await $0.simpleQuery("SET GLOBAL local_infile = \(before)") }
            throw error
        }
        try await server.withClient { _ = try await $0.simpleQuery("SET GLOBAL local_infile = \(before)") }
    }

    private func makeTable(_ client: MySQLClient, _ schema: String, label: String = "TEXT") async throws {
        try await client.admin.createTable(schema: schema, name: "t", columns: [
            MySQLColumnDefinition(name: "id", dataType: "INT", isNullable: false),
            MySQLColumnDefinition(name: "label", dataType: label),
        ], primaryKey: ["id"])
    }

    @Test(arguments: [true, false])
    func everyValueArrivesUnchanged(localInfile: Bool) async throws {
        let server = try TestServer.require()
        try await withLocalInfile(localInfile) {
            try await server.withSchema { client, schema in
                try await makeTable(client, schema)
                let progress = ProgressLog()
                let summary = try await client.importRows(into: "t", schema: schema, columns: ["id", "label"], rows: Self.awkward,
                                                          batchSize: 4) { await progress.add($0) }
                #expect(summary.method == (localInfile ? .loadDataLocal : .insertStatements))
                #expect(summary.rowCount == 11 && summary.batches == 3)
                #expect(await progress.values == [4, 8, 11])
                let back = try await client.simpleQuery("SELECT id, label FROM `\(schema)`.t ORDER BY id")
                #expect(back.map { $0.column("label")?.string } == Self.awkward.map { $0[1] })
            }
        }
    }

    @Test(arguments: [true, false])
    func aRefusedRowLeavesTheTableAsItWas(localInfile: Bool) async throws {
        let server = try TestServer.require()
        try await withLocalInfile(localInfile) {
            try await server.withSchema { client, schema in
                try await makeTable(client, schema, label: "VARCHAR(3)")
                var rows: [[String?]] = (1...10).map { [String($0), "ok"] }
                rows[6][1] = "far too long"
                await #expect(throws: (any Error).self) {
                    _ = try await client.importRows(into: "t", schema: schema, columns: ["id", "label"], rows: rows, batchSize: 4)
                }
                #expect(try await client.metadata.exactRowCount(schema: schema, table: "t") == 0)
            }
        }
    }

    @Test(arguments: [true, false])
    func duplicateKeysAreRefused(localInfile: Bool) async throws {
        let server = try TestServer.require()
        try await withLocalInfile(localInfile) {
            try await server.withSchema { client, schema in
                try await makeTable(client, schema)
                await #expect(throws: (any Error).self) {
                    _ = try await client.importRows(into: "t", schema: schema, columns: ["id", "label"], rows: [["1", "a"], ["1", "b"]])
                }
                #expect(try await client.metadata.exactRowCount(schema: schema, table: "t") == 0)
            }
        }
    }
}

actor ProgressLog {
    var values: [Int] = []
    func add(_ value: Int) { values.append(value) }
}
