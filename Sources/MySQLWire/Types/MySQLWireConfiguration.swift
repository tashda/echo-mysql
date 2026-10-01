import Foundation

/// How a connection uses TLS, as MySQL's `--ssl-mode` names it.
public enum MySQLWireTLSMode: Sendable, Hashable {
    /// No TLS.
    case disabled
    /// TLS when the server offers it, plain otherwise; the certificate is not checked (`PREFERRED`,
    /// the default of MySQL's own client). Only for servers that may have no TLS at all.
    case preferred
    /// Encrypt, but do not check the server's certificate (`REQUIRED`): works with the
    /// self-signed certificates MySQL and MariaDB generate at install.
    case required
    /// Encrypt and check the certificate chain against the CA, not the host name (`VERIFY_CA`).
    case verifyCA(caCertificatePath: String)
    /// Encrypt and check chain and host name (`VERIFY_IDENTITY`); the system roots when no CA is given.
    case verifyIdentity(caCertificatePath: String? = nil)
}

public struct MySQLWireConfiguration: Sendable, Hashable {
    public let host: String
    public let port: Int
    public let username: String
    public let password: String?
    public let database: String?
    public let tlsMode: MySQLWireTLSMode
    public let connectTimeoutSeconds: Int
    public let keepAliveInterval: Duration?
    /// A client certificate (PEM) and its key (PEM) for accounts created `REQUIRE X509` or
    /// `REQUIRE SUBJECT`. Only used with TLS.
    public let clientCertificatePath: String?
    public let clientKeyPath: String?

    /// True unless TLS is disabled.
    public var useTLS: Bool { tlsMode != .disabled }

    public init(
        host: String,
        port: Int = 3306,
        username: String,
        password: String? = nil,
        database: String? = nil,
        tlsMode: MySQLWireTLSMode,
        connectTimeoutSeconds: Int = 10,
        keepAliveInterval: Duration? = .seconds(300),
        clientCertificatePath: String? = nil,
        clientKeyPath: String? = nil
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.database = database
        self.tlsMode = tlsMode
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.keepAliveInterval = keepAliveInterval
        self.clientCertificatePath = clientCertificatePath
        self.clientKeyPath = clientKeyPath
    }

    /// `useTLS: true` verifies chain and host name against the system roots (`.verifyIdentity()`).
    public init(
        host: String,
        port: Int = 3306,
        username: String,
        password: String? = nil,
        database: String? = nil,
        useTLS: Bool = true,
        connectTimeoutSeconds: Int = 10,
        keepAliveInterval: Duration? = .seconds(300)
    ) {
        self.init(host: host, port: port, username: username, password: password, database: database,
                  tlsMode: useTLS ? .verifyIdentity() : .disabled, connectTimeoutSeconds: connectTimeoutSeconds,
                  keepAliveInterval: keepAliveInterval)
    }
}
