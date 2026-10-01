import Foundation
import MySQLKit
import MySQLKitTesting
import Testing

/// A primary (`MYSQL_TEST_URL`) and a replica that follows it (`MYSQL_TEST_REPLICA_URL`).
@Suite(.testServer(TestServer.replicaVariable), .serialized)
struct ReplicationTests {
    /// The primary, from `MYSQL_TEST_URL`.
    static func primary() throws -> TestServer {
        guard let primary = try TestServer.load(TestServer.defaultVariable) else {
            throw TestServerError.missing(variable: TestServer.defaultVariable)
        }
        return primary
    }

    /// Waits up to `seconds` for `condition`.
    static func eventually(seconds: Int = 30, _ condition: () async throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(250))
        }
        return false
    }

    @Test func replicaFollowsThePrimary() async throws {
        let replica = try TestServer.require()
        let primary = try Self.primary()
        try await replica.withClient { replicaClient in
            let state = try #require(try await replicaClient.replication.replicaState())
            #expect(state.ioRunning && state.sqlRunning, "\(state.lastError ?? "")")
            #expect(state.lastError == nil)

            try await primary.withSchema { primaryClient, schema in
                #expect(try await primaryClient.replication.primaryStatus()?.rawValues["File"] != nil)
                try await primaryClient.admin.createTable(schema: schema, name: "events",
                                                          columns: [MySQLColumnDefinition(name: "v", dataType: "INT")])
                _ = try await primaryClient.bulk.insert(into: "events", schema: schema, columns: ["v"],
                                                        rows: (1...50).map { [MySQLData(int: $0)] })
                let arrived = try await Self.eventually {
                    guard try await replicaClient.metadata.listTables(in: schema).contains(where: { $0.name == "events" }) else { return false }
                    return try await replicaClient.metadata.exactRowCount(schema: schema, table: "events") == 50
                }
                #expect(arrived, "the replica did not receive the rows within 30 seconds")
            }
        }
    }

    @Test func replicaIsReadOnly() async throws {
        let replica = try TestServer.require()
        try await replica.withClient { client in
            let readOnly = try await client.serverConfig.globalVariables(named: "read_only").first?.value
            #expect(readOnly == "ON")
            // MySQL's super_read_only stops administrators too; MariaDB's read_only does not.
            guard try await client.serverFlavor().isMySQL else { return }
            let name = TestServer.uniqueName("on_replica")
            await #expect(throws: (any Error).self) { try await client.admin.createDatabase(name: name) }
            try? await client.admin.dropDatabase(name: name)
        }
    }

    @Test func stopAndStartTheReplica() async throws {
        let replica = try TestServer.require()
        try await replica.withClient { client in
            try await client.replication.stopReplica()
            let stopped = try #require(try await client.replication.replicaState())
            #expect(!stopped.ioRunning && !stopped.sqlRunning)
            try await client.replication.startReplica()
            let running = try await Self.eventually(seconds: 20) {
                let state = try await client.replication.replicaState()
                return state?.ioRunning == true && state?.sqlRunning == true
            }
            #expect(running)
        }
    }
}
