
enum MySQLBindRenderer {
    static func renderLiteral(_ data: MySQLData) throws -> String {
        if data.type == .null || data.buffer == nil {
            return "NULL"
        }
        if let string = data.string {
            return "'\(escapeStringLiteral(string))'"
        }
        if let int = data.int {
            return String(int)
        }
        if let double = data.double {
            return String(double)
        }
        if let bool = data.bool {
            return bool ? "1" : "0"
        }
        throw MySQLWireError.unsupportedBindParameter(String(describing: data))
    }

    static func escapeStringLiteral(_ value: String) -> String {
        var escaped = String()
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "'":
                escaped.append("''")
            case "\\":
                escaped.append("\\\\")
            default:
                escaped.append(character)
            }
        }
        return escaped
    }
}
