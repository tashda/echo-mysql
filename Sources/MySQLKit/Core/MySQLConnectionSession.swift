import Foundation

public protocol MySQLConnectionSession: Sendable {
    func simpleQuery(_ sql: String) async throws -> [MySQLRow]
    func query(_ sql: String, binds: [MySQLData]) async throws -> MySQLWireQueryResult
    func stream(_ sql: String) async throws -> MySQLRowStream
    func changeDatabase(_ database: String) async throws
    func currentDatabase() async throws -> String?
    func validate() async throws
    func close() async
    /// Whether the session can no longer run statements (closed, or ended by the server).
    var isClosed: Bool { get async }
    /// The server's id for this connection (`KILL QUERY <id>`).
    var threadID: UInt64 { get async }
}

public extension MySQLConnectionSession {
    var isClosed: Bool { get async { false } }
    var threadID: UInt64 { get async { 0 } }
}
