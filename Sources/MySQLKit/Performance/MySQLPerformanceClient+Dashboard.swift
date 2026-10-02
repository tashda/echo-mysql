public extension MySQLPerformanceClient {
    func dashboardStatus() async throws -> [MySQLStatusVariable] {
        try await MySQLServerConfigClient(serverConnection: serverConnection).globalStatus()
    }
}
