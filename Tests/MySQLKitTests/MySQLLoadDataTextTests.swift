import Foundation
import Testing
@testable import MySQLKit

/// The text LOAD DATA reads, and its statement whatever the server's sql_mode.
@Suite("LOAD DATA text")
struct MySQLLoadDataTextTests {
    @Test func escapesWhatLoadDataReadsSpecially() {
        let data = MySQLLoadDataText.render([["a\tb", "c\\d", nil], ["line\nbreak", "cr\r", "nul\u{0}"]])
        #expect(String(decoding: data, as: UTF8.self) == "a\\tb\tc\\\\d\t\\N\nline\\nbreak\tcr\\r\tnul\\0\n")
    }

    @Test func statementSuitsTheEscapeMode() {
        let normal = MySQLLoadDataText.statement(table: "t`x", schema: "s", columns: ["a", "b"], name: "f.tsv", noBackslashEscapes: false)
        #expect(normal.hasPrefix("LOAD DATA LOCAL INFILE 'f.tsv' INTO TABLE `s`.`t``x` CHARACTER SET utf8mb4 "))
        #expect(normal.contains("ESCAPED BY '\\\\'"))
        #expect(normal.hasSuffix("(`a`, `b`)"))
        let strict = MySQLLoadDataText.statement(table: "t", schema: nil, columns: ["a"], name: "f.tsv", noBackslashEscapes: true)
        #expect(strict.contains("ESCAPED BY '\\'"))
        #expect(strict.contains("INTO TABLE `t` "))
    }
}
