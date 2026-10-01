import NIOSSL
import Testing
@testable import MySQLWire

struct MySQLWireConfigurationTests {
    @Test
    func defaultsMatchExpectedDesktopClientBehavior() {
        let configuration = MySQLWireConfiguration(host: "db.example.com", username: "echo")

        #expect(configuration.port == 3306)
        #expect(configuration.useTLS)
        #expect(configuration.connectTimeoutSeconds == 10)
        #expect(configuration.keepAliveInterval == .seconds(300))
    }
}


@Suite struct MySQLWireTLSModeTests {
    @Test func useTLSKeepsItsMeaning() {
        #expect(MySQLWireConfiguration(host: "h", username: "u", useTLS: true).tlsMode == .verifyIdentity())
        #expect(MySQLWireConfiguration(host: "h", username: "u", useTLS: false).tlsMode == .disabled)
    }

    @Test func requiredDoesNotVerify() throws {
        #expect(MySQLWireConnection.tlsConfiguration(for: .required)?.certificateVerification == CertificateVerification.none)
        #expect(MySQLWireConnection.tlsConfiguration(for: .verifyCA(caCertificatePath: "/ca.pem"))?.certificateVerification == .noHostnameVerification)
        #expect(MySQLWireConnection.tlsConfiguration(for: .disabled) == nil)
        // A client certificate only matters with TLS; a missing file is an error, not a silent skip.
        let plain = MySQLWireConfiguration(host: "h", username: "u", tlsMode: .disabled, clientCertificatePath: "/nope.pem", clientKeyPath: "/nope.key")
        #expect(try MySQLWireConnection.tlsConfiguration(for: plain) == nil)
        let missing = MySQLWireConfiguration(host: "h", username: "u", tlsMode: .required, clientCertificatePath: "/nope.pem", clientKeyPath: "/nope.key")
        #expect(throws: (any Error).self) { try MySQLWireConnection.tlsConfiguration(for: missing) }
    }

    @Test func addressesAreNotSentAsServerName() {
        #expect(MySQLWireConnection.serverName(for: MySQLWireConfiguration(host: "192.168.1.153", username: "u", tlsMode: .required)) == nil)
        #expect(MySQLWireConnection.serverName(for: MySQLWireConfiguration(host: "::1", username: "u", tlsMode: .required)) == nil)
        #expect(MySQLWireConnection.serverName(for: MySQLWireConfiguration(host: "db.example.com", username: "u", tlsMode: .required)) == "db.example.com")
    }
}
