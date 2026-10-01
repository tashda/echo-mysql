import Foundation
import MySQLKit
import Testing

/// The tools get the connection's TLS settings, in their own dialect (MySQL's `--ssl-mode`,
/// MariaDB's `--ssl` options).
@Suite("TLS options for the command-line tools")
struct MySQLToolTLSTests {
    private func configuration(_ mode: MySQLTLSMode, certificate: String? = nil, key: String? = nil) -> MySQLConfiguration {
        MySQLConfiguration(host: "db.example", username: "u", tlsMode: mode, clientCertificatePath: certificate, clientKeyPath: key)
    }

    @Test func flavorComesFromTheVersion() {
        #expect(MySQLToolFlavor(versionOutput: "mysqldump  Ver 8.4.3 for macos15.0 on arm64 (Homebrew)") == .mysql)
        #expect(MySQLToolFlavor(versionOutput: "mysqldump from 11.4.5-MariaDB, client 10.19 for osx10.20 (arm64)") == .mariadb)
        #expect(MySQLToolFlavor(versionOutput: "mariadb-dump from 11.8.2-MariaDB, client 10.19") == .mariadb)
    }

    @Test func mysqlToolsUseSSLMode() throws {
        #expect(try configuration(.disabled).toolTLS(for: .mysql).arguments == ["--ssl-mode=DISABLED"])
        #expect(try configuration(.preferred).toolTLS(for: .mysql).arguments == ["--ssl-mode=PREFERRED"])
        #expect(try configuration(.required).toolTLS(for: .mysql).arguments == ["--ssl-mode=REQUIRED"])
        #expect(try configuration(.verifyCA(caCertificatePath: "/ca.pem")).toolTLS(for: .mysql).arguments
            == ["--ssl-mode=VERIFY_IDENTITY", "--ssl-ca=/ca.pem"])
        #expect(try configuration(.verifyIdentity(caCertificatePath: "/ca.pem")).toolTLS(for: .mysql).arguments
            == ["--ssl-mode=VERIFY_IDENTITY", "--ssl-ca=/ca.pem"])
    }

    @Test func mariadbToolsUseTheirOwnOptions() throws {
        #expect(try configuration(.disabled).toolTLS(for: .mariadb).arguments == ["--skip-ssl"])
        #expect(try configuration(.required).toolTLS(for: .mariadb).arguments == ["--ssl", "--skip-ssl-verify-server-cert"])
        #expect(try configuration(.verifyIdentity(caCertificatePath: "/ca.pem")).toolTLS(for: .mariadb).arguments
            == ["--ssl", "--ssl-verify-server-cert", "--ssl-ca=/ca.pem"])
    }

    @Test func verifyIdentityWithoutACAUsesTheTrustedCAs() throws {
        let arguments = try configuration(.verifyIdentity()).toolTLS(for: .mysql).arguments
        let ca = try #require(arguments.first { $0.hasPrefix("--ssl-ca=") }?.dropFirst("--ssl-ca=".count))
        #expect(FileManager.default.fileExists(atPath: String(ca)))
    }

    @Test func commandsCarryTheOptions() {
        let client = MySQLClient(configuration: configuration(.required))
        let backup = client.backupRestore.backupCommand(
            host: "db.example", port: 3306, username: "u", database: "shop", outputPath: "/tmp/x.sql",
            options: MySQLDumpOptions(), tlsArguments: ["--ssl-mode=REQUIRED"]
        )
        #expect(backup.contains("--ssl-mode=REQUIRED"))
        #expect(backup.last == "shop")
        let restore = client.backupRestore.restoreCommand(
            host: "db.example", port: 3306, username: "u", database: "shop", inputPath: "/tmp/x.sql",
            tlsArguments: ["--ssl-mode=REQUIRED"]
        )
        #expect(restore.firstIndex(of: "--ssl-mode=REQUIRED")! < restore.firstIndex(of: "shop")!)
    }
}
