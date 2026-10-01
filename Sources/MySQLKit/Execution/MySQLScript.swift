import Foundation

/// Splits a SQL script into statements the way the `mysql` client does: `DELIMITER` lines change
/// the delimiter, quotes (with backslash escapes) and comments never end a statement, `--` and `#`
/// comments are dropped, block comments (including `/*!50001 … */` version comments) are kept.
public enum MySQLScript {
    public static func statements(_ script: String) -> [String] {
        let bytes = Array(script.utf8)
        var statements: [String] = []
        var current: [UInt8] = []
        var delimiter: [UInt8] = Array(";".utf8)
        var index = 0
        var lineStart = true

        func flush() {
            let text = String(decoding: current, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { statements.append(text) }
            current.removeAll(keepingCapacity: true)
        }
        func matches(_ token: [UInt8], at position: Int) -> Bool {
            position + token.count <= bytes.count && Array(bytes[position..<position + token.count]) == token
        }

        while index < bytes.count {
            let byte = bytes[index]
            // DELIMITER is a client command: only at the start of a line, between statements.
            if lineStart, current.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) {
                var cursor = index
                while cursor < bytes.count, bytes[cursor] == 0x20 || bytes[cursor] == 0x09 { cursor += 1 }
                if cursor + 10 <= bytes.count,
                   String(decoding: bytes[cursor..<cursor + 9], as: UTF8.self).uppercased() == "DELIMITER",
                   bytes[cursor + 9] == 0x20 || bytes[cursor + 9] == 0x09 {
                    var end = cursor + 10
                    while end < bytes.count, bytes[end] != 0x0A, bytes[end] != 0x0D { end += 1 }
                    let token = String(decoding: bytes[(cursor + 10)..<end], as: UTF8.self).trimmingCharacters(in: .whitespaces)
                    if !token.isEmpty { delimiter = Array(token.utf8) }
                    current.removeAll()
                    index = end
                    continue
                }
            }
            lineStart = byte == 0x0A
            switch byte {
            case 0x27, 0x22, 0x60:  // ' " `
                let quote = byte
                current.append(byte)
                index += 1
                while index < bytes.count {
                    let next = bytes[index]
                    current.append(next)
                    index += 1
                    if next == 0x5C, quote != 0x60, index < bytes.count {  // backslash escape
                        current.append(bytes[index])
                        index += 1
                    } else if next == quote {
                        break
                    }
                }
                continue
            case 0x2D where matches(Array("--".utf8), at: index)
                && (index + 2 >= bytes.count || [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index + 2])),
                 0x23:  // -- comment, # comment
                while index < bytes.count, bytes[index] != 0x0A { index += 1 }
                continue
            case 0x2F where matches(Array("/*".utf8), at: index):
                let start = index
                index += 2
                while index < bytes.count, !matches(Array("*/".utf8), at: index) { index += 1 }
                index = min(index + 2, bytes.count)
                current += bytes[start..<index]
                continue
            default:
                break
            }
            if matches(delimiter, at: index) {
                flush()
                index += delimiter.count
                continue
            }
            current.append(byte)
            index += 1
        }
        flush()
        return statements
    }
}

/// Runs scripts (sample databases, schema dumps) statement by statement on one connection.
public struct MySQLScriptClient: Sendable {
    let serverConnection: MySQLServerConnection

    /// Runs every statement of `script`, in `database` when given. Returns how many ran.
    @discardableResult
    public func run(_ script: String, database: String? = nil) async throws -> Int {
        let connection = try await serverConnection.primary()
        if let database { try await connection.changeDatabase(database) }
        let statements = MySQLScript.statements(script)
        for (index, statement) in statements.enumerated() {
            do {
                _ = try await connection.simpleQuery(statement)
            } catch {
                throw MySQLScriptError(statementNumber: index + 1, statement: String(statement.prefix(200)), underlying: "\(error)")
            }
        }
        return statements.count
    }
}

public struct MySQLScriptError: Error, CustomStringConvertible, Sendable {
    public let statementNumber: Int
    public let statement: String
    public let underlying: String
    public var description: String { "Statement \(statementNumber) failed: \(underlying)\n\(statement)" }
}
