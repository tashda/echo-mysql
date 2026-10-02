
public struct MySQLTransactionClient: Sendable {
    let serverConnection: MySQLServerConnection

    public func begin() async throws {
        let connection = try await serverConnection.primary()
        _ = try await connection.simpleQuery("START TRANSACTION")
    }

    public func commit() async throws {
        let connection = try await serverConnection.primary()
        _ = try await connection.simpleQuery("COMMIT")
    }

    public func rollback() async throws {
        let connection = try await serverConnection.primary()
        _ = try await connection.simpleQuery("ROLLBACK")
    }

    public func withTransaction<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await begin()
        do {
            let value = try await operation()
            try await commit()
            return value
        } catch {
            try? await rollback()
            throw error
        }
    }
}
