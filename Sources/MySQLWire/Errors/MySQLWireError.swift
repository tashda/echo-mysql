import Foundation

public enum MySQLWireError: LocalizedError, Sendable {
    case connectionAlreadyClosed
    case missingDatabaseName
    case unsupportedBindParameter(String)
    /// No session within the configured connect timeout (TCP connect, TLS and login together).
    case connectTimedOut(host: String, seconds: Int)

    public var errorDescription: String? {
        switch self {
        case .connectionAlreadyClosed:
            return "The MySQL connection is already closed."
        case .missingDatabaseName:
            return "A database name is required for this operation."
        case .unsupportedBindParameter(let description):
            return "Unsupported MySQL bind parameter: \(description)"
        case .connectTimedOut(let host, let seconds):
            return "Could not connect to \(host) within \(seconds) seconds."
        }
    }
}
