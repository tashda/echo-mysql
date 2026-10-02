import Foundation

/// Rows as `LOAD DATA` reads them: fields split by a tab, rows by a newline, `\N` for NULL, and
/// backslash escapes for backslash, tab, newline, carriage return and NUL.
enum MySQLLoadDataText {
    static func render(_ rows: some Sequence<[String?]>) -> Data {
        var data = Data()
        for row in rows {
            for (index, field) in row.enumerated() {
                if index > 0 { data.append(0x09) }
                guard let field else {
                    data.append(contentsOf: [0x5C, 0x4E]) // \N
                    continue
                }
                for byte in field.utf8 {
                    switch byte {
                    case 0x5C: data.append(contentsOf: [0x5C, 0x5C])
                    case 0x09: data.append(contentsOf: [0x5C, 0x74])
                    case 0x0A: data.append(contentsOf: [0x5C, 0x6E])
                    case 0x0D: data.append(contentsOf: [0x5C, 0x72])
                    case 0x00: data.append(contentsOf: [0x5C, 0x30])
                    default: data.append(byte)
                    }
                }
            }
            data.append(0x0A)
        }
        return data
    }

    /// The statement for one batch. The separators are written as the characters themselves,
    /// and the escape character to suit `NO_BACKSLASH_ESCAPES`, so the server's `sql_mode`
    /// cannot change how the data is read.
    static func statement(table: String, schema: String?, columns: [String], name: String, noBackslashEscapes: Bool) -> String {
        let target = [schema, table].compactMap { $0 }.map(quote).joined(separator: ".")
        let escape = noBackslashEscapes ? "'\\'" : "'\\\\'"
        return "LOAD DATA LOCAL INFILE '\(name)' INTO TABLE \(target) CHARACTER SET utf8mb4 "
            + "FIELDS TERMINATED BY '\t' ENCLOSED BY '' ESCAPED BY \(escape) LINES TERMINATED BY '\n' STARTING BY '' "
            + "(\(columns.map(quote).joined(separator: ", ")))"
    }

    static func quote(_ identifier: String) -> String {
        "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`"
    }
}
