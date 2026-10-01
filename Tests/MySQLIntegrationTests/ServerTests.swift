import Foundation
import MySQLKit
import MySQLKitTesting
import Testing

/// Server-wide reading and administration: variables, status, activity, performance reports,
/// maintenance, execution plans, logs, plugins and replication status.
@Suite(.testServer)
struct ServerTests {
    @Test func globalVariablesAndStatus() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            let all = try await client.serverConfig.globalVariables()
            #expect(all.count > 100)
            let one = try await client.serverConfig.globalVariables(named: "max_connections")
            #expect(one.map(\.name) == ["max_connections"])
            #expect(Int(one.first?.value ?? "") ?? 0 > 0)
            #expect(try await client.serverConfig.globalStatus(named: "Uptime").first.flatMap { Int($0.value) } ?? 0 > 0)
            #expect(try await !client.performance.dashboardStatus().isEmpty)
        }
    }

    /// A global variable nothing else in the suite depends on, set and reset.
    @Test func setAndResetAGlobalVariable() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            let original = try #require(try await client.serverConfig.globalVariables(named: "max_connect_errors").first?.value)
            let changed = try await client.serverConfig.setGlobalVariable("max_connect_errors", to: "4321")
            #expect(changed.name == "max_connect_errors")
            #expect(try await client.serverConfig.globalVariables(named: "max_connect_errors").first?.value == "4321")
            _ = try await client.serverConfig.setGlobalVariable("max_connect_errors", to: original)
            #expect(try await client.serverConfig.globalVariables(named: "max_connect_errors").first?.value == original)
        }
    }

    @Test func processListSnapshotAndKill() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            let other = server.client()
            defer { Task { await other.close() } }
            let otherID = try #require(try await other.simpleQuery("SELECT CONNECTION_ID() AS id").first?.column("id")?.int)
            let sleeper = Task { try await other.simpleQuery("SELECT SLEEP(20) AS s") }
            try await Task.sleep(for: .milliseconds(500))

            let processes = try await client.activity.processList()
            let sleeping = try #require(processes.first { $0.id == UInt32(otherID) })
            #expect(sleeping.info?.contains("SLEEP(20)") == true)
            let snapshot = try await client.activity.snapshot()
            #expect(snapshot.processes.contains { $0.id == UInt32(otherID) })

            try await client.activity.killQuery(threadID: UInt32(otherID))
            _ = try? await sleeper.value
            let after = try await client.activity.processList().first { $0.id == UInt32(otherID) }
            #expect(after?.info?.contains("SLEEP(20)") != true)
        }
    }

    @Test func performanceReportsRun() async throws {
        let server = try TestServer.require()
        let flavor = try await server.flavor()
        try await server.withClient { client in
            #expect(try await !client.performance.innodbStatus().statusText.isEmpty)
            // The sys schema ships with MySQL, and with MariaDB since 10.6.
            guard flavor.isMySQL || flavor.atLeast(10, 6) else { return }
            _ = try await client.performance.topRuntimeStatements()
            _ = try await client.performance.fullTableScans()
            _ = try await client.performance.schemaIndexStatistics()
            _ = try await client.performance.schemaTableStatistics()
            _ = try await client.performance.waitsGlobalByLatency()
            _ = try await client.performance.waitsByUserByLatency()
            _ = try await client.performance.hostSummary()
            _ = try await client.performance.memoryGlobalByCurrentBytes()
            _ = try await client.performance.ioGlobalByFileByBytes()
            _ = try await client.performance.statementAnalysis()
            _ = try await client.performance.unusedIndexes()
        }
    }

    @Test func maintenanceStatements() async throws {
        let server = try TestServer.require()
        try await server.withSchema { client, schema in
            try await client.admin.createTable(schema: schema, name: "t", columns: [MySQLColumnDefinition(name: "a", dataType: "INT")])
            try await client.admin.createTable(schema: schema, name: "m", columns: [MySQLColumnDefinition(name: "a", dataType: "INT")],
                                               options: MySQLTableOptions(engine: "MyISAM"))
            #expect(try await !client.maintenance.analyzeTable(schema: schema, table: "t").messages.isEmpty)
            #expect(try await !client.maintenance.optimizeTable(schema: schema, table: "t").messages.isEmpty)
            #expect(try await client.maintenance.checkTable(schema: schema, table: "t").messages.contains { $0.contains("OK") })
            #expect(try await !client.maintenance.checkTables(schema: schema, tables: ["t", "m"]).messages.isEmpty)
            #expect(try await !client.maintenance.repairTable(schema: schema, table: "m").messages.isEmpty)
            try await client.maintenance.flushTables()
        }
    }

    @Test func executionPlans() async throws {
        let server = try TestServer.require()
        let flavor = try await server.flavor()
        try await server.withSchema { client, schema in
            try await client.admin.createTable(schema: schema, name: "t", columns: [
                MySQLColumnDefinition(name: "id", dataType: "INT", isNullable: false),
            ], primaryKey: ["id"])
            let plan = try await client.executionPlan.explain("SELECT * FROM `\(schema)`.t WHERE id = 1")
            #expect(!plan.rows.isEmpty)
            let json = try await client.executionPlan.explainJSON("SELECT * FROM `\(schema)`.t WHERE id = 1")
            // MySQL 9 writes a newer JSON format than 8.x and MariaDB; any of them is a JSON object.
            #expect((try? JSONSerialization.jsonObject(with: Data(json.json.utf8))) is [String: Any])
            if flavor.isMySQL {
                let analyzed = try await client.executionPlan.explainAnalyze("SELECT * FROM `\(schema)`.t")
                #expect(!analyzed.lines.isEmpty)
            }
        }
    }

    @Test func logsPluginsAndReplicationStatus() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            let destinations = try await client.errorLog.logDestinations()
            #expect(!destinations.isEmpty)
            let plugins = try await client.metadata.listPlugins()
            #expect(plugins.contains { $0.name.lowercased() == "innodb" })
            // A plain server is no replica; its binary log may be on or off.
            #expect(try await client.replication.replicaStatus() == nil)
            _ = try await client.replication.primaryStatus()
        }
    }
}
