import Foundation
import MDBConnector

public enum MySQLWireError: LocalizedError, Sendable {
    case connectionAlreadyClosed
    case missingDatabaseName
    case unsupportedBindParameter(String)
    /// No session within the configured connect timeout (TCP connect, TLS and login together).
    case connectTimedOut(host: String, seconds: Int)
    /// The primary connection closed with a transaction open; calls fail until
    /// `MySQLClient.reconnect()`, so later statements don't silently run outside it.
    case transactionLost

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
        case .transactionLost:
            return "The connection was lost with a transaction open, and the server rolled it back. Reconnect to continue."
        }
    }
}

/// An error from the server or the connection, with MySQL's error number and SQLSTATE.
public struct MySQLError: Error, LocalizedError, Sendable, Equatable {
    /// MySQL error number (1064 syntax, 1146 no table, 1317 interrupted; 2000+ client errors).
    public let code: UInt32
    public let sqlState: String?
    public let message: String
    /// The connection is gone (the server closed it, the network broke).
    public let isConnectionLost: Bool

    public var errorDescription: String? { message }

    /// The statement was stopped (`KILL QUERY`, Cancel).
    public var isCancelled: Bool { code == 1317 }
    /// The statement ran past its time limit (MySQL `max_execution_time` 3024, MariaDB `max_statement_time` 1969).
    public var isTimeout: Bool { code == 3024 || code == 1969 }

    init(_ error: MDBError) {
        code = error.code
        sqlState = error.sqlState
        message = error.message
        isConnectionLost = error.kind == .connectionLost
    }

    /// Any error from the driver in MySQLKit's terms; others pass through.
    static func from(_ error: any Error) -> any Error {
        if let error = error as? MDBError {
            if error.kind == .connectTimedOut { return error }
            return MySQLError(error)
        }
        return error
    }
}

extension MDBError: LocalizedError {
    public var errorDescription: String? { message }
}
