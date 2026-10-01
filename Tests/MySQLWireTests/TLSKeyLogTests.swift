import Foundation
import NIOCore
import NIOSSL
import Testing
@testable import MySQLWire

@Suite struct TLSKeyLogTests {
    @Test func keyLoggingIsOffUnlessAsked() {
        var configuration = TLSConfiguration.makeClientConfiguration()
        TLSKeyLog.apply(to: &configuration, environment: [:])
        #expect(configuration.keyLogCallback == nil)
        TLSKeyLog.apply(to: &configuration, environment: ["SSLKEYLOGFILE": "/tmp/keys"])
        #expect(configuration.keyLogCallback != nil)
    }

    @Test func linesAreAppendedOnePerSecret() throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "keylog-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        TLSKeyLog.append(ByteBuffer(string: "CLIENT_RANDOM aa bb"), to: path)
        TLSKeyLog.append(ByteBuffer(string: "CLIENT_RANDOM cc dd\n"), to: path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "CLIENT_RANDOM aa bb\nCLIENT_RANDOM cc dd\n")
    }
}
