/// A server plugin from `information_schema.PLUGINS`.
public struct MySQLPluginInfo: Sendable, Hashable {
    public let name: String
    /// `ACTIVE`, `INACTIVE`, `DISABLED`, `DELETED`.
    public let status: String
    /// `AUTHENTICATION`, `STORAGE ENGINE`, `DAEMON`, …
    public let type: String
    /// Nil for plugins built into the server.
    public let library: String?
}

public extension MySQLMetadataClient {
    func listPlugins() async throws -> [MySQLPluginInfo] {
        let connection = try await serverConnection.metadata()
        let result = try await connection.query(
            "SELECT PLUGIN_NAME, PLUGIN_STATUS, PLUGIN_TYPE, PLUGIN_LIBRARY FROM information_schema.PLUGINS ORDER BY PLUGIN_NAME",
            binds: [])
        return result.rows.map { row in
            MySQLPluginInfo(name: row.field("PLUGIN_NAME")?.string ?? "", status: row.field("PLUGIN_STATUS")?.string ?? "",
                            type: row.field("PLUGIN_TYPE")?.string ?? "", library: row.field("PLUGIN_LIBRARY")?.string)
        }
    }
}
