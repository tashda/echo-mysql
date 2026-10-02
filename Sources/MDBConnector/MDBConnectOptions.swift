/// How a connection is opened (what MySQLKit builds from its configuration).
public struct MDBConnectOptions: Sendable, Equatable {
    public enum TLS: Sendable, Equatable {
        /// No TLS.
        case disabled
        /// TLS when the server offers it, plaintext otherwise; the certificate is not checked.
        case preferred
        /// TLS always (never plaintext); the certificate is not checked.
        case required
        /// TLS, and the certificate checked (chain and host name) against `caPath`.
        case verifyIdentity(caPath: String)
    }

    public var host: String
    public var port: Int
    /// A Unix socket path instead of host/port.
    public var unixSocket: String?
    public var user: String
    public var password: String?
    public var database: String?
    public var connectTimeoutSeconds: Int
    public var tls: TLS
    public var clientCertificatePath: String?
    public var clientKeyPath: String?
    public var clientKeyPassword: String?
    /// `LOAD DATA LOCAL INFILE` (decision D17: only on an import connection).
    public var allowLocalInfile = false
    public var compress = false
    /// Sends the password in clear text (LDAP/PAM, RDS IAM): only allowed with a checked certificate.
    public var allowCleartextPassword = false
    /// For `caching_sha2_password` without TLS: the server's RSA public key file (decision D18).
    public var serverPublicKeyPath: String?

    public init(host: String, port: Int = 3306, user: String, password: String? = nil, database: String? = nil,
                connectTimeoutSeconds: Int = 10, tls: TLS = .preferred) {
        self.host = host
        self.port = port
        self.user = user
        self.password = password
        self.database = database
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.tls = tls
    }
}
