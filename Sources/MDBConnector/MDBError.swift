/// A failure from MariaDB Connector/C or the server.
public struct MDBError: Error, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Connecting failed (host, TLS, sign-in): see `message`.
        case connectFailed
        /// The connect deadline passed.
        case connectTimedOut
        /// The connection broke (server gone, lost during query, closed).
        case connectionLost
        /// The connection is closed or busy with another statement.
        case notReady
        /// The server rejected a statement (`code`, `sqlState`).
        case server
    }

    public let kind: Kind
    /// MySQL error number (1064, 1317 …; 2002+ are client errors).
    public let code: UInt32
    public let sqlState: String?
    public let message: String

    public init(_ kind: Kind, code: UInt32 = 0, sqlState: String? = nil, message: String) {
        self.kind = kind
        self.code = code
        self.sqlState = sqlState
        self.message = message
    }

    /// Client error numbers that mean the connection is gone.
    static let connectionLostCodes: Set<UInt32> = [
        2006, // CR_SERVER_GONE_ERROR
        2013, // CR_SERVER_LOST
        2055, // CR_SERVER_LOST_EXTENDED
        4031, // ER_CLIENT_INTERACTION_TIMEOUT (MySQL 8.0.24+)
    ]
}
