import Foundation
import MySQLKit

/// A test server URL, in the form MySQL's own clients use:
///
///     mysql://root:pass@localhost:3306/?ssl-mode=PREFERRED
///     mysql://root:pass@host:3306/app?ssl-mode=VERIFY_IDENTITY&ssl-ca=/ca.pem&ssl-cert=/c.pem&ssl-key=/k.pem
///
/// User and password are percent-encoded (`p%40ss` for `p@ss`). The path names the database to
/// connect to first (none for `/`). `ssl-mode` is `DISABLED`, `PREFERRED` (the default, as in the
/// `mysql` client), `REQUIRED`, `VERIFY_CA` or `VERIFY_IDENTITY`; `connect-timeout` is in seconds.
/// MariaDB servers use the same form (`mariadb://` is accepted too).
public enum MySQLTestURLError: Error, Equatable, CustomStringConvertible {
    case malformed(String)
    case unsupportedScheme(String)
    case missingHost
    case missingUser
    case unknownSSLMode(String)
    case missingCA(String)
    case incompleteClientCertificate

    public var description: String {
        switch self {
        case .malformed(let url): return "Not a URL: \(url)"
        case .unsupportedScheme(let scheme): return "The URL's scheme is \(scheme); expected mysql://"
        case .missingHost: return "The URL names no host"
        case .missingUser: return "The URL names no user"
        case .unknownSSLMode(let mode): return "Unknown ssl-mode \(mode): use DISABLED, PREFERRED, REQUIRED, VERIFY_CA or VERIFY_IDENTITY"
        case .missingCA(let mode): return "ssl-mode=\(mode) needs ssl-ca"
        case .incompleteClientCertificate: return "ssl-cert and ssl-key go together"
        }
    }
}

public extension MySQLWireConfiguration {
    /// Parses a test server URL (see `MySQLTestURLError` for the form).
    init(testURL url: String, connectTimeoutSeconds: Int = 10) throws {
        guard let components = URLComponents(string: url) else { throw MySQLTestURLError.malformed(url) }
        guard let scheme = components.scheme?.lowercased(), scheme == "mysql" || scheme == "mariadb" else {
            throw MySQLTestURLError.unsupportedScheme(components.scheme ?? "")
        }
        // An IPv6 address comes back in brackets on some platforms.
        guard let host = components.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), !host.isEmpty else {
            throw MySQLTestURLError.missingHost
        }
        guard let user = components.user, !user.isEmpty else { throw MySQLTestURLError.missingUser }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name.lowercased()] = item.value ?? "" }
        let ca = query["ssl-ca"].flatMap { $0.isEmpty ? nil : $0 }
        let certificate = query["ssl-cert"].flatMap { $0.isEmpty ? nil : $0 }
        let key = query["ssl-key"].flatMap { $0.isEmpty ? nil : $0 }
        guard (certificate == nil) == (key == nil) else { throw MySQLTestURLError.incompleteClientCertificate }

        let mode = (query["ssl-mode"] ?? "PREFERRED").uppercased()
        let tlsMode: MySQLWireTLSMode
        switch mode {
        case "DISABLED": tlsMode = .disabled
        case "PREFERRED": tlsMode = .preferred
        case "REQUIRED": tlsMode = .required
        case "VERIFY_CA":
            guard let ca else { throw MySQLTestURLError.missingCA(mode) }
            tlsMode = .verifyCA(caCertificatePath: ca)
        case "VERIFY_IDENTITY": tlsMode = .verifyIdentity(caCertificatePath: ca)
        default: throw MySQLTestURLError.unknownSSLMode(mode)
        }

        let database = components.path.split(separator: "/").first.map(String.init)
        self.init(
            host: host,
            port: components.port ?? 3306,
            username: user,
            password: components.password,
            database: database,
            tlsMode: tlsMode,
            connectTimeoutSeconds: query["connect-timeout"].flatMap(Int.init) ?? connectTimeoutSeconds,
            keepAliveInterval: nil,
            clientCertificatePath: certificate,
            clientKeyPath: key
        )
    }
}
