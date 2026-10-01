import MySQLWire

public extension MySQLSessionClient {
    func acquireNamedLock(_ name: String, timeoutSeconds: Int = 0) async throws -> MySQLNamedLockResult {
        let connection = try await serverConnection.primary()
        let result = try await connection.query(
            "SELECT GET_LOCK(?, ?) AS lock_acquired",
            binds: [MySQLData(string: name), MySQLData(int: timeoutSeconds)]
        )
        let acquired = result.rows.first?.field("lock_acquired")?.string == "1"
        return MySQLNamedLockResult(name: name, acquired: acquired)
    }

    func releaseNamedLock(_ name: String) async throws -> MySQLNamedLockResult {
        let connection = try await serverConnection.primary()
        let result = try await connection.query(
            "SELECT RELEASE_LOCK(?) AS lock_released",
            binds: [MySQLData(string: name)]
        )
        let released = result.rows.first?.field("lock_released")?.string == "1"
        return MySQLNamedLockResult(name: name, acquired: released)
    }
}
