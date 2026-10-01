import Foundation

public protocol MySQLConnectionSession: Sendable {
    func simpleQuery(_ sql: String) async throws -> [MySQLRow]
    func query(_ sql: String, binds: [MySQLData]) async throws -> MySQLWireQueryResult
    func stream(_ sql: String) async throws -> AsyncThrowingStream<MySQLRow, Error>
    func changeDatabase(_ database: String) async throws
    func currentDatabase() async throws -> String?
    func validate() async throws
    func close() async
    /// Whether the session can no longer run statements (closed, or ended by the server).
    var isClosed: Bool { get async }
}

public extension MySQLConnectionSession {
    var isClosed: Bool { get async { false } }
}
