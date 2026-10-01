#if canImport(CMariaDB)
internal import CMariaDB
#else
internal import CMariaDBSystem
#endif
import Foundation

extension MDBConnection {
    /// A path that never exists: no client plugin is ever loaded from disk (all are built in).
    static let noPluginDirectory = "/var/empty/echo-no-plugins"

    /// Decision D18: without TLS, `caching_sha2_password` and `sha256_password` full sign-ins
    /// encrypt the password with the server's RSA key, which Connector/C fetches in plaintext
    /// unless it has a key file (a man in the middle could hand it their own). Pointing it at this
    /// file, which holds no key, makes those sign-ins fail instead, as MySQL's own client does.
    /// A key file the user chose replaces it.
    static let needsTLSOrKeyFile = "This account signs in with caching_sha2_password or sha256_password, which needs TLS to send the password safely. Turn on TLS for this connection, or choose the server's public key file."

    static let noServerKeyFile: String = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("echo-no-server-public-key.pem")
        try? Data("Echo never fetches a server's RSA key in plaintext (no key file was chosen).\n".utf8).write(to: url)
        return url.path
    }()

    func open(_ options: MDBConnectOptions) async throws {
        guard handle == nil else { throw MDBError(.notReady, message: "The connection is already open.") }
        guard let mysql = mysql_init(nil) else { throw MDBError(.connectFailed, message: "Connector/C could not allocate a connection.") }
        handle = mysql
        _ = mysql_options(mysql, MYSQL_OPT_NONBLOCK, nil)
        setString(MYSQL_SET_CHARSET_NAME, "utf8mb4")
        setString(MYSQL_PLUGIN_DIR, Self.noPluginDirectory)
        var timeout = UInt32(max(1, options.connectTimeoutSeconds))
        _ = mysql_options(mysql, MYSQL_OPT_CONNECT_TIMEOUT, &timeout)
        try applyTLS(options)
        var localInfile = UInt32(options.allowLocalInfile ? 1 : 0)
        _ = mysql_options(mysql, MYSQL_OPT_LOCAL_INFILE, &localInfile)
        installLocalInfileHandler()
        if options.compress { _ = mysql_options(mysql, MYSQL_OPT_COMPRESS, nil) }
        var cleartext: CChar
        if case .verifyIdentity = options.tls, options.allowCleartextPassword { cleartext = 1 } else { cleartext = 0 }
        _ = mysql_options(mysql, MYSQL_ENABLE_CLEARTEXT_PLUGIN, &cleartext)
        setString(MYSQL_SERVER_PUBLIC_KEY, options.serverPublicKeyPath ?? Self.noServerKeyFile)

        // Connector/C keeps these pointers until the connect is done.
        let host = options.unixSocket == nil ? strdup(options.host) : nil
        let user = strdup(options.user)
        let password = options.password.flatMap { strdup($0) }
        let database = options.database.flatMap { strdup($0) }
        let socket = options.unixSocket.flatMap { strdup($0) }
        defer {
            free(host); free(user); free(database); free(socket)
            if let password { memset(password, 0, strlen(password)); free(password) }
        }
        let flags = UInt(CLIENT_MULTI_STATEMENTS) | UInt(CLIENT_MULTI_RESULTS) | UInt(CLIENT_PS_MULTI_RESULTS)
        var connected: UnsafeMutablePointer<MYSQL>?
        do {
            try await drive(deadline: .now + .seconds(max(1, options.connectTimeoutSeconds))) {
                mysql_real_connect_start(&connected, mysql, host, user, password, database, UInt32(options.port), socket, flags)
            } resume: { ready in
                mysql_real_connect_cont(&connected, mysql, ready)
            }
        } catch is MDBSocketTimeout {
            await close()
            throw MDBError(.connectTimedOut, message: "The server did not answer in time.")
        } catch {
            await close()
            throw error
        }
        guard connected != nil else {
            var failure = self.error(.connectFailed)
            // The sign-in plugin stopped at the placeholder key file (D18); Connector/C has no words for it.
            if failure.code == 2000, tlsCipher == nil, options.serverPublicKeyPath == nil {
                failure = MDBError(.connectFailed, code: 2061, sqlState: failure.sqlState, message: Self.needsTLSOrKeyFile)
            }
            await close()
            throw failure
        }
        if options.tls == .required, tlsCipher == nil {
            await close()
            throw MDBError(.connectFailed, code: 2026, message: "The server does not support TLS, and this connection requires it.")
        }
    }

    /// TLS per mode (Connector/C 3.4 turns TLS on by itself unless told otherwise).
    private func applyTLS(_ options: MDBConnectOptions) throws {
        guard let mysql = handle else { return }
        var on: CChar = 1, off: CChar = 0
        switch options.tls {
        case .disabled:
            _ = mysql_options(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &off)
            _ = mysql_options(mysql, MYSQL_OPT_SSL_ENFORCE, &off)
            return
        case .preferred:
            _ = mysql_options(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &off)
            _ = mysql_options(mysql, MYSQL_OPT_SSL_ENFORCE, &on)
        case .required:
            // Encrypt without checking the certificate. Connector/C would carry on in plaintext
            // with a server that has no TLS; `open` refuses such a connection right after the
            // handshake (no clear-text password is sent: that plugin is off unless TLS is checked).
            _ = mysql_options(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &off)
            _ = mysql_options(mysql, MYSQL_OPT_SSL_ENFORCE, &on)
        case .verifyIdentity(let caPath):
            _ = mysql_options(mysql, MYSQL_OPT_SSL_ENFORCE, &on)
            _ = mysql_options(mysql, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &on)
            setString(MYSQL_OPT_SSL_CA, caPath)
        }
        setString(MARIADB_OPT_TLS_VERSION, "TLSv1.2,TLSv1.3")
        if let certificate = options.clientCertificatePath { setString(MYSQL_OPT_SSL_CERT, certificate) }
        if let key = options.clientKeyPath { setString(MYSQL_OPT_SSL_KEY, key) }
        if let passphrase = options.clientKeyPassword { setString(MARIADB_OPT_TLS_PASSPHRASE, passphrase) }
    }

    /// String options are copied by Connector/C.
    private func setString(_ option: mysql_option, _ value: String) {
        guard let mysql = handle else { return }
        _ = value.withCString { mysql_options(mysql, option, $0) }
    }
}
