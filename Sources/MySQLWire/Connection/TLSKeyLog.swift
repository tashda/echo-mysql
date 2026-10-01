import Foundation
import NIOCore
import NIOSSL

/// Writes TLS session secrets in the NSS key log format to the file `SSLKEYLOGFILE` names, as
/// browsers, curl and the mysql client do, so Wireshark can decrypt a capture of the connection.
/// Off unless the variable is set.
enum TLSKeyLog {
    private static let lock = NSLock()

    static func apply(to configuration: inout TLSConfiguration,
                      environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let path = environment["SSLKEYLOGFILE"], !path.isEmpty else { return }
        configuration.keyLogCallback = { line in append(line, to: path) }
    }

    static func append(_ line: ByteBuffer, to path: String) {
        var text = String(buffer: line)
        if !text.hasSuffix("\n") { text += "\n" }
        lock.withLock {
            if !FileManager.default.fileExists(atPath: path) {
                FileManager.default.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        }
    }
}
