import Foundation
import MySQLKit
import MySQLKitTesting
import MySQLWire
import Testing

struct MySQLInfrastructureTests {
    @Test
    func preparedStatementCacheEvictsLeastRecentlyUsed() async {
        let cache = PreparedStatementCache(capacity: 2)

        await cache.touch("SELECT 1", statementName: "s1", now: Date(timeIntervalSince1970: 1))
        await cache.touch("SELECT 2", statementName: "s2", now: Date(timeIntervalSince1970: 2))
        await cache.touch("SELECT 1", statementName: "s1", now: Date(timeIntervalSince1970: 3))
        await cache.touch("SELECT 3", statementName: "s3", now: Date(timeIntervalSince1970: 4))

        let entries = await cache.cachedStatements()

        #expect(entries.map(\.sql) == ["SELECT 1", "SELECT 3"])
        #expect(await cache.contains("SELECT 2") == false)
    }

    @Test
    func connectionHealthPolicyClassifiesReconnectErrors() {
        struct SampleError: LocalizedError {
            let message: String
            var errorDescription: String? { message }
        }

        let policy = MySQLConnectionHealthPolicy()

        #expect(policy.action(for: SampleError(message: "MySQL server has gone away")) == .reconnectRequired)
        #expect(policy.action(for: SampleError(message: "broken pipe")) == .closeRequired)
        #expect(policy.action(for: SampleError(message: "syntax error")) == .noAction)
    }

    @Test
    func serverConnectionTracksPreparedStatements() async throws {
        let connection = MockConnectionSession()
        let serverConnection = MySQLServerConnection(
            configuration: MySQLConfiguration(host: "localhost", username: "root"),
            connectionFactory: { _, _ in
                connection
            }
        )

        await serverConnection.recordPreparedStatement("SELECT 1")
        await serverConnection.recordPreparedStatement("SELECT 2")

        let cached = await serverConnection.cachedPreparedStatements()
        await serverConnection.resetPreparedStatements()

        #expect(cached.map { $0.sql } == ["SELECT 1", "SELECT 2"])
        #expect(await serverConnection.cachedPreparedStatements().isEmpty)
    }

    /// Callers that arrive while the connection is being opened wait for it instead of opening
    /// their own (the replaced one was never closed).
    @Test
    func concurrentCallersShareOneConnection() async throws {
        actor Counter { var opened = 0; func open() { opened += 1 } }
        let counter = Counter()
        let serverConnection = MySQLServerConnection(
            configuration: MySQLConfiguration(host: "localhost", username: "root"),
            connectionFactory: { _, _ in
                await counter.open()
                try await Task.sleep(for: .milliseconds(50))
                return MockConnectionSession()
            }
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 1...5 { group.addTask { _ = try await serverConnection.metadata() } }
            try await group.waitForAll()
        }
        #expect(await counter.opened == 1)
    }
}
