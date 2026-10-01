import Foundation
import MDBConnector
import Testing

@Suite("MDBConnection on a lab server", .labServer, .serialized)
struct MDBConnectionTests {
    @Test func connectsAndReportsTheServer() async throws {
        let connection = try await LabServer.connect()
        #expect(await connection.threadID > 0)
        #expect(await connection.serverVersion > 50_000)
        #expect(await !connection.serverInfo.isEmpty)
        let events = try await connection.execute("SELECT @@character_set_client, @@character_set_results")
        #expect(events.compactMap(\.rows).first?.first?.string(0) == "utf8mb4")
        #expect(await connection.isAlive())
        await connection.close()
        #expect(await !connection.isOpen)
    }

    @Test func severalStatementsGiveSeveralResults() async throws {
        let connection = try await LabServer.connectWithDatabase()
        defer { Task { await connection.close() } }
        let events = try await connection.execute("""
            CREATE TEMPORARY TABLE t (i INT PRIMARY KEY, d DECIMAL(65,30), at DATETIME(6), span TIME, y YEAR, b BIT(64), j JSON);
            INSERT INTO t VALUES (1, 12345678901234567890.123456789012345678901234567890, '2026-10-01 12:34:56.123456', '-838:59:59', 2026, b'101', '{"a": [1, 2]}'), (2, NULL, NULL, NULL, NULL, NULL, NULL);
            SELECT i, d, at, span, y, b, j FROM t ORDER BY i
            """)
        let dones = events.compactMap(\.done)
        #expect(dones.count == 3)
        #expect(dones[1].affectedRows == 2)
        #expect(dones[1].info?.contains("Records: 2") == true)
        #expect(dones[2].returnedRows)
        let fields = try #require(events.compactMap(\.columns).first)
        #expect(fields.map(\.name) == ["i", "d", "at", "span", "y", "b", "j"])
        #expect(fields[5].isBinary)
        let rows = events.compactMap(\.rows).flatMap { $0 }
        #expect(rows.count == 2)
        #expect(rows[0].string(1) == "12345678901234567890.123456789012345678901234567890")
        #expect(rows[0].string(2) == "2026-10-01 12:34:56.123456")
        #expect(rows[0].string(3) == "-838:59:59")
        #expect(rows[0].string(4) == "2026")
        #expect(rows[0].data(5) == Data([0, 0, 0, 0, 0, 0, 0, 5]))
        #expect(rows[0].string(6)?.contains("\"a\"") == true)
        #expect(rows[1].isNull(1) && rows[1].isNull(6))
        #expect(await !connection.isBusy)
    }

    @Test func anErrorStopsTheBatch() async throws {
        let connection = try await LabServer.connectWithDatabase()
        defer { Task { await connection.close() } }
        try await connection.send("SELECT 1; SELECT * FROM no_such_table_x; SELECT 3")
        var seen: [MDBEvent] = []
        do {
            while let event = try await connection.nextEvent() { seen.append(event) }
            Issue.record("no error")
        } catch let error as MDBError {
            #expect(error.kind == .server)
            #expect(error.code == 1146)
            #expect(error.sqlState == "42S02")
        }
        #expect(seen.compactMap(\.rows).flatMap { $0 }.first?.string(0) == "1")
        #expect(await !connection.isBusy)
        #expect(try await connection.execute("SELECT 4").compactMap(\.rows).first?.first?.string(0) == "4")
    }

    @Test func rowsComeInBatchesWithoutReadingAhead() async throws {
        let connection = try await LabServer.connect()
        defer { Task { await connection.close() } }
        // MySQL fails past cte_max_recursion_depth; MariaDB stops quietly at max_recursive_iterations (1000).
        _ = try? await connection.execute("SET SESSION cte_max_recursion_depth = 200000")
        _ = try? await connection.execute("SET SESSION max_recursive_iterations = 200000")
        try await connection.send("WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i < 100000) SELECT i, REPEAT('x', 20) FROM n")
        var rows = 0, batches = 0, last = ""
        while let event = try await connection.nextEvent(maxRows: 500) {
            if let batch = event.rows {
                rows += batch.count
                batches += 1
                #expect(batch.count <= 500)
                last = batch.last?.string(0) ?? last
            }
        }
        #expect(rows == 100_000)
        #expect(batches >= 200)
        #expect(last == "100000")
    }

    @Test func escapingFollowsTheServerMode() async throws {
        let connection = try await LabServer.connect()
        defer { Task { await connection.close() } }
        let tricky = "it's a \\ test \" with 'quotes'"
        let escaped = try await connection.escape(tricky)
        #expect(try await connection.execute("SELECT '\(escaped)'").compactMap(\.rows).first?.first?.string(0) == tricky)
        _ = try await connection.execute("SET SESSION sql_mode = CONCAT(@@sql_mode, ',NO_BACKSLASH_ESCAPES')")
        let doubled = try await connection.escape(tricky)
        #expect(try await connection.execute("SELECT '\(doubled)'").compactMap(\.rows).first?.first?.string(0) == tricky)
    }

    @Test func killQueryFromAnotherConnectionCancels() async throws {
        let connection = try await LabServer.connect()
        let killer = try await LabServer.connect()
        defer { Task { await connection.close(); await killer.close() } }
        let id = await connection.threadID
        let started = ContinuousClock.now
        // The server answers SELECT SLEEP only when it is done, so send from a task of its own.
        let running = Task { () -> Bool in
            do {
                try await connection.send("SELECT SLEEP(30)")
                var interrupted = false
                while let event = try await connection.nextEvent() {
                    // MySQL ends SLEEP with 1 instead of an error when interrupted.
                    if let value = event.rows?.first?.string(0), value == "1" { interrupted = true }
                }
                return interrupted
            } catch let error as MDBError {
                return error.code == 1317 // MariaDB: query interrupted
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        _ = try await killer.execute("KILL QUERY \(id)")
        #expect(try await running.value)
        #expect(ContinuousClock.now - started < .seconds(5))
        #expect(try await connection.execute("SELECT 1").compactMap(\.rows).first?.first?.string(0) == "1")
    }

    @Test func closeWhileAStatementWaits() async throws {
        let connection = try await LabServer.connect()
        let reader = Task {
            try await connection.send("SELECT SLEEP(30)")
            return try await connection.nextEvent()
        }
        try await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        await connection.close()
        await #expect(throws: MDBError.self) { _ = try await reader.value }
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    /// A call cut off mid-way can't be resumed by Connector/C, so the connection closes rather than
    /// letting the next statement start over a suspended one.
    @Test func cancellingAWaitingTaskClosesTheConnection() async throws {
        let connection = try await LabServer.connect()
        let reader = Task {
            try await connection.send("SELECT SLEEP(30)")
            return try await connection.nextEvent()
        }
        try await Task.sleep(for: .milliseconds(300))
        let started = ContinuousClock.now
        reader.cancel()
        await #expect(throws: CancellationError.self) { _ = try await reader.value }
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(await !connection.isOpen)
        await #expect(throws: MDBError.self) { try await connection.send("SELECT 1") }
    }

    @Test func aKilledConnectionIsNoticedWhileIdle() async throws {
        let connection = try await LabServer.connect()
        let killer = try await LabServer.connect()
        defer { Task { await killer.close() } }
        _ = try await killer.execute("KILL \(await connection.threadID)")
        try await Task.sleep(for: .milliseconds(300))
        #expect(await !connection.isAlive())
        await connection.close()
    }
}

@Suite("MDBConnection without a server")
struct MDBConnectionOfflineTests {
    @Test func connectDeadline() async throws {
        let options = MDBConnectOptions(host: "10.255.255.1", user: "x", connectTimeoutSeconds: 1, tls: .disabled)
        let started = ContinuousClock.now
        await #expect(throws: MDBError.self) { _ = try await MDBConnection.connect(options) }
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func refusedPort() async throws {
        let options = MDBConnectOptions(host: "127.0.0.1", port: 1, user: "x", connectTimeoutSeconds: 5, tls: .disabled)
        do {
            _ = try await MDBConnection.connect(options)
            Issue.record("connected")
        } catch let error as MDBError {
            #expect(error.kind == .connectFailed)
            #expect(error.code == 2002 || error.code == 2003)
        }
    }
}
