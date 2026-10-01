import Foundation
import MySQLKit
import MySQLKitTesting
import Testing

/// Which lab TLS server the run has (`SERVERLAB_RECIPE`); empty outside the lab.
enum LabTLSRecipe {
    static var name: String { ProcessInfo.processInfo.environment["SERVERLAB_RECIPE"] ?? "" }
    /// A server whose certificate must not pass a check (expired, self-signed, naming another host).
    static var hasBadCertificate: Bool {
        ["-tls-expired-certificate", "-tls-self-signed", "-tls-wrong-host"].contains { name.hasSuffix($0) }
    }
    static var isOptional: Bool { name.hasSuffix("-tls-optional") }
    static var isStrict: Bool { name.hasSuffix("-tls-strict") }
    /// The CA the test URL names (`ssl-ca`), whatever its mode.
    static var caPath: String? {
        ProcessInfo.processInfo.environment[TestServer.tlsVariable]
            .flatMap(URLComponents.init(string:))?.queryItems?.first { $0.name == "ssl-ca" }?.value
    }
    /// The servers `TLSTests` is written for: TLS required, a good certificate.
    static var requiresTLSWithAGoodCertificate: Bool { !hasBadCertificate && !isOptional }
}

/// The lab's certificate-check servers: every mode connects or refuses as it should (Phase 6
/// TLS matrix). Only modes that don't check the certificate get through.
@Suite(.testServer(TestServer.tlsVariable), .enabled(if: LabTLSRecipe.hasBadCertificate))
struct TLSCertificateCheckTests {
    static var labCA: String? { LabTLSRecipe.caPath }

    @Test func modesThatDontCheckTheCertificateConnectEncrypted() async throws {
        let server = try TestServer.require()
        for mode in [MySQLTLSMode.required, .preferred] {
            try await server.withClient(server.configuration(tlsMode: mode)) { client async throws in
                #expect(try await !TLSTests.cipher(client).isEmpty, "\(mode)")
            }
        }
    }

    @Test func modesThatCheckTheCertificateRefuse() async throws {
        let server = try TestServer.require()
        let ca = try #require(Self.labCA)
        for mode in [MySQLTLSMode.verifyCA(caCertificatePath: ca), .verifyIdentity(caCertificatePath: ca), .verifyIdentity()] {
            let client = server.client(server.configuration(tlsMode: mode))
            await #expect(throws: (any Error).self, "\(mode)") { _ = try await client.simpleQuery("SELECT 1") }
            await client.close()
        }
    }
}

/// A server where TLS is up to the client (`mysql-8.4-tls-optional`).
@Suite(.testServer(TestServer.tlsVariable), .enabled(if: LabTLSRecipe.isOptional))
struct TLSOptionalTests {
    @Test func eachModeGetsWhatItAsksFor() async throws {
        let server = try TestServer.require()
        let ca = try #require(LabTLSRecipe.caPath)
        try await server.withClient(server.configuration(tlsMode: .disabled)) { client async throws in
            #expect(try await TLSTests.cipher(client).isEmpty)
        }
        for mode in [MySQLTLSMode.preferred, .required, .verifyCA(caCertificatePath: ca), .verifyIdentity(caCertificatePath: ca)] {
            try await server.withClient(server.configuration(tlsMode: mode)) { client async throws in
                #expect(try await !TLSTests.cipher(client).isEmpty, "\(mode)")
            }
        }
    }
}
