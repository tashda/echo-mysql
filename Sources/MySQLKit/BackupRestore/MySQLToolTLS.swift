import Foundation

/// Whose command-line tools are installed: MySQL's (`--ssl-mode`) or MariaDB's (`--ssl`,
/// `--ssl-verify-server-cert`). Their TLS options differ, and each rejects the other's.
public enum MySQLToolFlavor: Sendable, Equatable {
    case mysql
    case mariadb

    /// From the tool's `--version` output: MariaDB's tools name MariaDB there
    /// ("mysqldump from 11.4.5-MariaDB", "mariadb-dump from 11.8.2-MariaDB").
    public init(versionOutput: String) {
        self = versionOutput.localizedCaseInsensitiveContains("mariadb") ? .mariadb : .mysql
    }
}

/// The TLS options for `mysqldump` or `mysql` that match a connection, so a backup or restore
/// is as protected as the connection itself. Keep it until the tool has finished: client
/// certificates converted for it (`.p12`, DER, PKCS#1) are deleted with it.
public struct MySQLToolTLS: Sendable {
    public let arguments: [String]
    /// Holds the converted certificate files.
    let setup: MySQLConnectorSetup
}

/// Why the tools can't use the connection's TLS settings.
public enum MySQLToolTLSError: LocalizedError, Equatable, Sendable {
    /// The tools can't be given a key password; they would wait for one on a terminal.
    case encryptedClientKey

    public var errorDescription: String? {
        switch self {
        case .encryptedClientKey:
            "The MySQL command-line tools can't use an encrypted client key. Use a key without a password for backups and restores."
        }
    }
}

extension MySQLConfiguration {
    /// The tools' TLS options for this connection. A missing CA with Verify Identity means the
    /// CAs this Mac trusts, as for the connection.
    public func toolTLS(for flavor: MySQLToolFlavor) throws -> MySQLToolTLS {
        let setup = try connectorSetup()
        var arguments: [String] = []
        switch (flavor, setup.options.tls) {
        case (.mysql, .disabled): arguments = ["--ssl-mode=DISABLED"]
        case (.mysql, .preferred): arguments = ["--ssl-mode=PREFERRED"]
        case (.mysql, .required): arguments = ["--ssl-mode=REQUIRED"]
        // Decision D19: the connection checks chain and name together, so the tools do too.
        case (.mysql, .verifyIdentity(let caPath)): arguments = ["--ssl-mode=VERIFY_IDENTITY", "--ssl-ca=\(caPath)"]
        case (.mariadb, .disabled): arguments = ["--skip-ssl"]
        // MariaDB's tools have no "TLS if offered": `--ssl` without verification is the closest.
        case (.mariadb, .preferred), (.mariadb, .required): arguments = ["--ssl", "--skip-ssl-verify-server-cert"]
        case (.mariadb, .verifyIdentity(let caPath)): arguments = ["--ssl", "--ssl-verify-server-cert", "--ssl-ca=\(caPath)"]
        }
        if setup.options.tls != .disabled, let certificate = setup.options.clientCertificatePath {
            guard setup.options.clientKeyPassword == nil else { throw MySQLToolTLSError.encryptedClientKey }
            arguments.append("--ssl-cert=\(certificate)")
            if let key = setup.options.clientKeyPath { arguments.append("--ssl-key=\(key)") }
        }
        return MySQLToolTLS(arguments: arguments, setup: setup)
    }
}
