import Foundation

/// Puts parameter values into SQL at its `?` placeholders. Placeholders inside string literals,
/// quoted identifiers and comments are left alone. Values are rendered as SQL literals by the
/// caller (escaped by the connection, which knows its character set and `NO_BACKSLASH_ESCAPES`).
enum MySQLPlaceholders {
    static func positions(in sql: String) -> [String.Index] {
        var positions: [String.Index] = []
        var index = sql.startIndex
        func peek(_ offset: Int) -> Character? {
            sql.index(index, offsetBy: offset, limitedBy: sql.endIndex).flatMap { $0 < sql.endIndex ? sql[$0] : nil }
        }
        while index < sql.endIndex {
            let character = sql[index]
            switch character {
            case "'", "\"", "`":
                // A quoted run; backslash escapes (except in identifiers) and doubled quotes.
                var cursor = sql.index(after: index)
                while cursor < sql.endIndex {
                    let current = sql[cursor]
                    if current == "\\", character != "`" {
                        cursor = sql.index(cursor, offsetBy: 2, limitedBy: sql.endIndex) ?? sql.endIndex
                        continue
                    }
                    if current == character {
                        let next = sql.index(after: cursor)
                        if next < sql.endIndex, sql[next] == character { cursor = sql.index(after: next); continue }
                        break
                    }
                    cursor = sql.index(after: cursor)
                }
                index = cursor < sql.endIndex ? sql.index(after: cursor) : sql.endIndex
                continue
            case "#":
                index = sql[index...].firstIndex(of: "\n") ?? sql.endIndex
                continue
            case "-" where peek(1) == "-" && (peek(2).map { $0 == " " || $0 == "\t" || $0 == "\n" } ?? true):
                index = sql[index...].firstIndex(of: "\n") ?? sql.endIndex
                continue
            case "/" where peek(1) == "*":
                if let end = sql.range(of: "*/", range: sql.index(index, offsetBy: 2)..<sql.endIndex) {
                    index = end.upperBound
                } else {
                    index = sql.endIndex
                }
                continue
            case "?":
                positions.append(index)
            default:
                break
            }
            index = sql.index(after: index)
        }
        return positions
    }

    /// The SQL with each `?` replaced by the matching literal.
    static func render(_ sql: String, literals: [String]) throws -> String {
        let places = positions(in: sql)
        guard places.count == literals.count else {
            throw MySQLWireError.unsupportedBindParameter("the statement has \(places.count) placeholders and \(literals.count) values")
        }
        var output = ""
        var last = sql.startIndex
        for (place, literal) in zip(places, literals) {
            output += sql[last..<place]
            output += literal
            last = sql.index(after: place)
        }
        output += sql[last...]
        return output
    }
}
