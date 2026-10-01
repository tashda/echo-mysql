import Foundation
import MySQLKit
import MySQLKitTesting
import Testing

/// Connecting, queries, binds, streaming and what happens when a connection is lost.
@Suite(.testServer)
struct ConnectionTests {
    @Test func connectsAndQueries() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            let rows = try await client.simpleQuery("SELECT 1 + 1 AS two, 'é😀' AS text")
            #expect(rows.first?.column("two")?.int == 2)
            #expect(rows.first?.column("text")?.string == "é😀")
            #expect(try await client.session.currentUser()?.isEmpty == false)
        }
    }

    /// Whether the server offers TLS: PREFERRED encrypts exactly then.
    static func serverOffersTLS(_ server: TestServer) async throws -> Bool {
        try await server.withClient(server.configuration(tlsMode: .preferred)) { client in
            let rows = try await client.simpleQuery("SHOW SESSION STATUS LIKE 'Ssl_cipher'")
            return !(rows.first?.column("Value")?.string ?? "").isEmpty
        }
    }

    @Test func requiredModesFailWhenTheServerHasNoTLS() async throws {
        let server = try TestServer.require()
        let offersTLS = try await Self.serverOffersTLS(server)
        let client = server.client(server.configuration(tlsMode: .required))
        defer { Task { await client.close() } }
        if offersTLS {
            let cipher = try await client.simpleQuery("SHOW SESSION STATUS LIKE 'Ssl_cipher'").first?.column("Value")?.string
            #expect(cipher?.isEmpty == false)
        } else {
            // REQUIRED never falls back to plaintext (fixed with MariaDB Connector/C).
            await #expect(throws: (any Error).self) { _ = try await client.simpleQuery("SELECT 1") }
        }
    }

    @Test func wrongPasswordIsAnAccessDeniedError() async throws {
        let server = try TestServer.require()
        let client = server.client(server.configuration(password: "definitely-not-the-password"))
        defer { Task { await client.close() } }
        let error = await #expect(throws: (any Error).self) { _ = try await client.simpleQuery("SELECT 1") }
        #expect("\(error.map { String(describing: $0) } ?? "")".localizedCaseInsensitiveContains("denied"))
    }

    @Test func unknownDatabaseFailsToConnect() async throws {
        let server = try TestServer.require()
        let client = server.client(server.configuration(database: .some("mwt_no_such_database")))
        defer { Task { await client.close() } }
        await #expect(throws: (any Error).self) { _ = try await client.simpleQuery("SELECT 1") }
    }

    @Test func connectsToTheURLsDatabaseAndSwitches() async throws {
        let server = try TestServer.require()
        try await server.withSchema { client, schema in
            let session = try await MySQLDedicatedSession.open(configuration: server.configuration(database: .some(schema)))
            defer { Task { await session.close() } }
            #expect(try await session.simpleQuery("SELECT DATABASE() AS db").first?.column("db")?.string == schema)
            try await client.metadata.selectDatabase(schema)
            #expect(try await client.metadata.currentDatabase() == schema)
        }
    }

    @Test func bindsOfEveryKindRoundTrip() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            let date = Date(timeIntervalSince1970: 1_700_000_000)
            let result = try await client.query(
                "SELECT ? AS i, ? AS d, ? AS s, ? AS n, ? AS b, ? AS quote, ? AS backslash, ? AS t",
                binds: [MySQLData(int: -42), MySQLData(double: 2.5), MySQLData(string: "héllo"), .null,
                        MySQLData(bool: true), MySQLData(string: "it's"), MySQLData(string: #"a\b"#), MySQLData(date: date)])
            let row = try #require(result.rows.first)
            #expect(row.column("i")?.int == -42)
            #expect(row.column("d")?.double == 2.5)
            #expect(row.column("s")?.string == "héllo")
            #expect(row.column("n")?.string == nil)
            #expect(row.column("b")?.int == 1)
            #expect(row.column("quote")?.string == "it's")
            #expect(row.column("backslash")?.string == #"a\b"#)
            #expect(row.column("t")?.date == date)
        }
    }

    /// Two different statements with binds, alternately: each must run itself, not the other.
    @Test func differentBoundStatementsDoNotMixUp() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            for round in 0..<3 {
                let first = try await client.query("SELECT ? AS value, 'first' AS which", binds: [MySQLData(int: round)])
                let second = try await client.query("SELECT ? * 10 AS value, 'second' AS which", binds: [MySQLData(int: round)])
                #expect(first.rows.first?.column("which")?.string == "first")
                #expect(first.rows.first?.column("value")?.int == round)
                #expect(second.rows.first?.column("which")?.string == "second")
                #expect(second.rows.first?.column("value")?.int == round * 10)
            }
        }
    }

    @Test func concurrentCallsOnOneClientGetTheirOwnResults() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            try await withThrowingTaskGroup(of: (Int, Int?, Int?).self) { group in
                for value in 0..<40 {
                    group.addTask {
                        let plain = try await client.simpleQuery("SELECT \(value) AS v").first?.column("v")?.int
                        let bound = try await client.query("SELECT ? AS v", binds: [MySQLData(int: value)]).rows.first?.column("v")?.int
                        return (value, plain, bound)
                    }
                }
                for try await (value, plain, bound) in group {
                    #expect(plain == value)
                    #expect(bound == value)
                }
            }
        }
    }

    @Test func streamsManyRows() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            let sql = "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 20000) SELECT i FROM n"
            // Both stop recursive CTEs at 1,000 levels by default (MariaDB since 11.x).
            let limit = try await client.serverFlavor().isMySQL ? "cte_max_recursion_depth" : "max_recursive_iterations"
            _ = try await client.simpleQuery("SET SESSION \(limit) = 100000")
            var count = 0
            var sum = 0
            for try await row in try await client.stream(sql) {
                count += 1
                sum += row.column("i")?.int ?? 0
            }
            #expect(count == 20000)
            #expect(sum == 20000 * 20001 / 2)
        }
    }

    @Test func abandonedStreamLeavesTheConnectionUsable() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            let stream = try await client.stream("SELECT table_name FROM information_schema.columns")
            for try await _ in stream { break }
            #expect(try await client.simpleQuery("SELECT 7 AS v").first?.column("v")?.int == 7)
        }
    }

    @Test func serverErrorsCarryTheirMessage() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            let error = await #expect(throws: (any Error).self) { _ = try await client.simpleQuery("SELECT * FROM mwt_missing.nothing") }
            #expect(error.map { String(describing: $0) }?.contains("mwt_missing") == true)
            // The connection carries on after an error.
            let after = try await client.simpleQuery("SELECT 1 AS v")
            #expect(after.first?.column("v")?.int == 1)
        }
    }

    /// The server ends the session (KILL, a restart, wait_timeout): a call in flight fails, and later
    /// calls get a new connection instead of failing for ever. Nothing is re-run.
    @Test func killedConnectionIsReplaced() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            let id = try #require(try await client.simpleQuery("SELECT CONNECTION_ID() AS id").first?.column("id")?.int)
            let inFlight = Task { try await client.simpleQuery("SELECT SLEEP(20)") }
            try await Task.sleep(for: .milliseconds(300))
            try await server.withClient { admin in _ = try await admin.simpleQuery("KILL CONNECTION \(id)") }
            await #expect(throws: (any Error).self) { _ = try await inFlight.value }
            let newID = try #require(try await client.simpleQuery("SELECT CONNECTION_ID() AS id").first?.column("id")?.int)
            #expect(newID != id)
        }
    }

    /// Lost with a transaction open: reported once, and calls fail until `reconnect()`, so no
    /// statement silently runs outside the transaction the user thinks is open.
    @Test func aConnectionLostInATransactionWaitsForReconnect() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            #expect(await client.checkConnection() == nil)
            _ = try await client.simpleQuery("START TRANSACTION")
            let id = try #require(try await client.simpleQuery("SELECT CONNECTION_ID() AS id").first?.column("id")?.int)
            try await server.withClient { admin in _ = try await admin.simpleQuery("KILL CONNECTION \(id)") }
            try await Task.sleep(for: .milliseconds(300))
            #expect(await client.checkConnection() == MySQLConnectionLoss(transactionLost: true))
            #expect(await client.checkConnection() == nil)
            await #expect(throws: MySQLWireError.self) { _ = try await client.simpleQuery("SELECT 1") }
            try await client.reconnect()
            #expect(await !client.isInTransaction)
            let newID = try #require(try await client.simpleQuery("SELECT CONNECTION_ID() AS id").first?.column("id")?.int)
            #expect(newID != id)
        }
    }

    /// Lost with nothing open: reported, and the next call opens a new connection.
    @Test func anIdleConnectionLostIsReportedAndReplaced() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            let id = try #require(try await client.simpleQuery("SELECT CONNECTION_ID() AS id").first?.column("id")?.int)
            try await server.withClient { admin in _ = try await admin.simpleQuery("KILL CONNECTION \(id)") }
            try await Task.sleep(for: .milliseconds(300))
            #expect(await client.checkConnection() == MySQLConnectionLoss(transactionLost: false))
            #expect(try await client.simpleQuery("SELECT 1 AS v").first?.column("v")?.int == 1)
        }
    }

    @Test func cancelQueryStopsALongStatement() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            let id = try #require(try await client.simpleQuery("SELECT CONNECTION_ID() AS id").first?.column("id")?.int)
            let started = ContinuousClock.now
            async let sleeping = client.simpleQuery("SELECT SLEEP(30) AS slept")
            try await Task.sleep(for: .milliseconds(500))
            try await client.activity.killQuery(threadID: UInt32(id))
            // KILL QUERY makes SLEEP return 1 (MySQL) or fail with "Query execution was interrupted".
            _ = try? await sleeping
            #expect(ContinuousClock.now - started < .seconds(10))
            #expect(try await client.simpleQuery("SELECT 2 AS v").first?.column("v")?.int == 2)
        }
    }

    /// Echo's Force Stop: the statement ends at once, the open transaction is reported (and rolled
    /// back by the server), and the next call gets a new connection.
    @Test func closeRunningConnectionStopsAStatementInATransaction() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            #expect(await !client.isInTransaction)
            _ = try await client.simpleQuery("START TRANSACTION")
            #expect(await client.isInTransaction)
            let id = try #require(try await client.simpleQuery("SELECT CONNECTION_ID() AS id").first?.column("id")?.int)
            let started = ContinuousClock.now
            let sleeping = Task { try await client.simpleQuery("SELECT SLEEP(30)") }
            try await Task.sleep(for: .milliseconds(500))
            let outcome = await client.closeRunningConnection()
            #expect(outcome.closed && outcome.transactionWasOpen)
            await #expect(throws: (any Error).self) { _ = try await sleeping.value }
            #expect(ContinuousClock.now - started < .seconds(5))
            #expect(await !client.isInTransaction)
            let newID = try #require(try await client.simpleQuery("SELECT CONNECTION_ID() AS id").first?.column("id")?.int)
            #expect(newID != id)
        }
    }

    /// A cancelled task ends its statement and its connection; the next call gets a new one.
    @Test func cancellingARunningCallReplacesTheConnection() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            let id = try #require(try await client.simpleQuery("SELECT CONNECTION_ID() AS id").first?.column("id")?.int)
            let sleeping = Task { try await client.simpleQuery("SELECT SLEEP(30)") }
            try await Task.sleep(for: .milliseconds(500))
            sleeping.cancel()
            await #expect(throws: (any Error).self) { _ = try await sleeping.value }
            let newID = try #require(try await client.simpleQuery("SELECT CONNECTION_ID() AS id").first?.column("id")?.int)
            #expect(newID != id)
        }
    }

    @Test func closedClientCanBeUsedAgain() async throws {
        let server = try TestServer.require()
        let client = server.client()
        #expect(try await client.simpleQuery("SELECT 1 AS v").count == 1)
        await client.close()
        #expect(try await client.simpleQuery("SELECT 1 AS v").count == 1)
        await client.close()
    }
}
