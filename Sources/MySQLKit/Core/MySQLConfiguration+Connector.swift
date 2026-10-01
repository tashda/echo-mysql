import Foundation
import MDBConnector
#if canImport(EchoTLS)
import EchoTLS
#endif

/// The files a connection was opened with (converted client certificates), kept while it lives.
struct MySQLConnectorSetup: Sendable {
    var options: MDBConnectOptions
    #if canImport(EchoTLS)
    var clientCertificate: ClientCertificateFiles?
    #endif
}

extension MySQLConfiguration {
    /// Connector/C options for this configuration (Phase 6, table 6.3).
    func connectorSetup() throws -> MySQLConnectorSetup {
        var options = MDBConnectOptions(host: host, port: port, user: username, password: password, database: database,
                                        connectTimeoutSeconds: connectTimeoutSeconds, tls: .disabled)
        if host.hasPrefix("/") { options.unixSocket = host }
        options.allowLocalInfile = allowLocalInfile
        options.serverPublicKeyPath = serverPublicKeyPath
        switch tlsMode {
        case .disabled: options.tls = .disabled
        case .preferred: options.tls = .preferred
        case .required: options.tls = .required
        // Decision D19: Connector/C checks chain and name together, so Verify CA is Verify Identity.
        case .verifyCA(let caPath): options.tls = .verifyIdentity(caPath: caPath)
        case .verifyIdentity(let caPath): options.tls = .verifyIdentity(caPath: try caPath ?? Self.systemTrustBundle())
        }
        #if canImport(EchoTLS)
        var setup = MySQLConnectorSetup(options: options)
        if tlsMode != .disabled, let certificate = clientCertificatePath {
            let files = try ClientCertificateFiles.make(certificatePath: certificate, keyPath: clientKeyPath, password: clientKeyPassword)
            setup.options.clientCertificatePath = files.certificatePath
            setup.options.clientKeyPath = files.keyPath
            setup.options.clientKeyPassword = files.keyPassword
            setup.clientCertificate = files
        }
        return setup
        #else
        options.clientCertificatePath = clientCertificatePath
        options.clientKeyPath = clientKeyPath
        options.clientKeyPassword = clientKeyPassword
        return MySQLConnectorSetup(options: options)
        #endif
    }

    /// The CAs this Mac trusts (OpenSSL doesn't read the Keychain), as a PEM file.
    static func systemTrustBundle() throws -> String {
        #if canImport(EchoTLS)
        try TrustBundle.currentPath()
        #else
        "/etc/ssl/certs/ca-certificates.crt"
        #endif
    }
}
