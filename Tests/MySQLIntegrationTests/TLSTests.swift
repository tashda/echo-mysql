import Foundation
import MySQLKit
import MySQLKitTesting
import Testing

/// A server that requires TLS (`MYSQL_TEST_TLS_URL`). Tests that need the CA or a client
/// certificate return early when the URL has none (`ssl-ca`, `ssl-cert`, `ssl-key`).
@Suite(.testServer(TestServer.tlsVariable), .enabled(if: LabTLSRecipe.requiresTLSWithAGoodCertificate))
struct TLSTests {
    /// A CA that signed nothing on any test server: verifying against it must fail.
    static let unrelatedCA = """
        -----BEGIN CERTIFICATE-----
        MIIDGjCCAgKgAwIBAgIUFM1vILkNw1ooCjrblWHSh2aseAIwDQYJKoZIhvcNAQEL
        BQAwLDEqMCgGA1UEAwwhbXlzcWwtd2lyZSB0ZXN0czogYW4gdW5yZWxhdGVkIENB
        MCAXDTI2MTAwMTA4MjA1MloYDzIxMjYwOTA3MDgyMDUyWjAsMSowKAYDVQQDDCFt
        eXNxbC13aXJlIHRlc3RzOiBhbiB1bnJlbGF0ZWQgQ0EwggEiMA0GCSqGSIb3DQEB
        AQUAA4IBDwAwggEKAoIBAQDtZ6EORoW88A9kWT1lBVUVt7Jva0ZJTCuX+SDlrXUO
        gwaxUsEAVJ2v/wB13OpdHZ4HbxoyVqq9yPey0UOXRL9lx9hAxpMIgTG6JghXcTAZ
        zMzE3OzZ39anmUHE1ZwbD5XJtwIG7QjH4L6vMgINJjTTgybDdlMbp+Fmbk/+mveG
        wlPokK9ChN2jBmqdqKABGdEtCWKSipVqLAbTtgNnfv4D69xK0SszUGRAx9ieeaiq
        Kg/RZEWmnt4DWy0/8e9G802qXOM8Ua5phtm70U2uTlnWe28CPAfoSpn+pP7wFuTZ
        JLzvAlWzvhs50/hFek8IVX8jdTYyeis+pNTRyUWZ9vi/AgMBAAGjMjAwMB0GA1Ud
        DgQWBBRUP/z9E6VIt9t1Ipz4a6gmCy1UvzAPBgNVHRMBAf8EBTADAQH/MA0GCSqG
        SIb3DQEBCwUAA4IBAQDCWQ8ovOxVKIyXZKaVEs8TL7EHDNhSiivglZpd6P8s2Uf6
        G+IdjPx92GH+w5GL7S2x1DXNdX25iicoDNxGyFPcRqKud2ZqORYfezRI7Jutu/TB
        FR+xkNF5SG52XN1Lm1Eq6k6ahN6aownxAXA48wBL9INuTPyHJrtA6koMhvKkr5xn
        MYRuKxcR1fiBaDpxHgxaKlv+Zjy71WwYFMWDd+lWH9utGLVhTCfQrsit1s8I/ygh
        IHJRJFihRotLqrcA2EjITJ1UdepeLcKTAb/BSFlq78QBL41LmJ7ilQFuO4GBq85p
        XCp23jqZn4gc+Z3m4EeO1H/rh3zQT3d1fIFSBTGb
        -----END CERTIFICATE-----
        """

    static func unrelatedCAFile() throws -> String {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("mysql-wire-unrelated-ca.pem").path
        try unrelatedCA.write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    static func cipher(_ client: MySQLClient) async throws -> String {
        try await client.simpleQuery("SHOW SESSION STATUS LIKE 'Ssl_cipher'").first?.column("Value")?.string ?? ""
    }

    static var caPath: String? {
        switch TestServer.current?.configuration.tlsMode {
        case .verifyCA(let path)?: return path
        case .verifyIdentity(let path)?: return path
        default: return nil
        }
    }

    @Test func theURLsSettingsConnectEncrypted() async throws {
        let server = try TestServer.require()
        try await server.withClient { client async throws in
            #expect(try await !Self.cipher(client).isEmpty)
            let version = try await client.simpleQuery("SHOW SESSION STATUS LIKE 'Ssl_version'").first?.column("Value")?.string
            #expect(version?.hasPrefix(LabTLSRecipe.isStrict ? "TLSv1.3" : "TLSv1.") == true)
        }
    }

    @Test func plainConnectionsAreRefused() async throws {
        let server = try TestServer.require()
        let client = server.client(server.configuration(tlsMode: .disabled))
        defer { Task { await client.close() } }
        await #expect(throws: (any Error).self) { _ = try await client.simpleQuery("SELECT 1") }
    }

    @Test func requiredEncryptsWithoutCheckingTheCertificate() async throws {
        let server = try TestServer.require()
        try await server.withClient(server.configuration(tlsMode: .required)) { client async throws in
            #expect(try await !Self.cipher(client).isEmpty)
        }
    }

    @Test func verifyingAgainstTheRightCASucceedsAndTheWrongOneFails() async throws {
        let server = try TestServer.require()
        guard let ca = Self.caPath else { return }
        try await server.withClient(server.configuration(tlsMode: .verifyCA(caCertificatePath: ca))) { client async throws in
            #expect(try await !Self.cipher(client).isEmpty)
        }
        let wrong = server.client(server.configuration(tlsMode: .verifyCA(caCertificatePath: try Self.unrelatedCAFile())))
        defer { Task { await wrong.close() } }
        await #expect(throws: (any Error).self) { _ = try await wrong.simpleQuery("SELECT 1") }
        let wrongIdentity = server.client(server.configuration(tlsMode: .verifyIdentity(caCertificatePath: try Self.unrelatedCAFile())))
        defer { Task { await wrongIdentity.close() } }
        await #expect(throws: (any Error).self) { _ = try await wrongIdentity.simpleQuery("SELECT 1") }
    }

    /// An account created REQUIRE X509 logs in with the URL's client certificate and not without.
    @Test func clientCertificateLogsInAnX509Account() async throws {
        let server = try TestServer.require()
        guard let certificate = server.configuration.clientCertificatePath, let key = server.configuration.clientKeyPath else { return }
        try await server.withClient { admin in
            let user = TestServer.uniqueName("x509")
            defer { Task { _ = try? await server.withClient { try await $0.security.dropUser(username: user, host: "%") } } }
            _ = try await admin.security.createUser(username: user, host: "%", password: "X509-Password1", tls: .x509)

            let withCertificate = server.client(server.configuration(username: user, password: .some("X509-Password1"),
                                                                     clientCertificatePath: .some(certificate), clientKeyPath: .some(key)))
            defer { Task { await withCertificate.close() } }
            #expect(try await withCertificate.session.currentUser()?.hasPrefix(user) == true)

            let withoutCertificate = server.client(server.configuration(username: user, password: .some("X509-Password1"),
                                                                        clientCertificatePath: .some(nil), clientKeyPath: .some(nil)))
            defer { Task { await withoutCertificate.close() } }
            await #expect(throws: (any Error).self) { _ = try await withoutCertificate.simpleQuery("SELECT 1") }
        }
    }

    @Test func missingCertificateFilesFailClearly() async throws {
        let server = try TestServer.require()
        let client = server.client(server.configuration(clientCertificatePath: .some("/nonexistent/client.pem"),
                                                        clientKeyPath: .some("/nonexistent/client.key")))
        defer { Task { await client.close() } }
        await #expect(throws: (any Error).self) { _ = try await client.simpleQuery("SELECT 1") }
    }
}
