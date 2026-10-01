import Testing
@testable import MySQLKit

@Suite struct MySQLScriptTests {
    @Test func delimiterBlocksKeepTheirSemicolons() {
        let script = """
        -- a comment; with a semicolon
        CREATE TABLE t (a INT); # another; comment
        DELIMITER $$
        CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END$$
        DELIMITER ;
        INSERT INTO t VALUES (1);
        """
        #expect(MySQLScript.statements(script) == [
            "CREATE TABLE t (a INT)",
            "CREATE PROCEDURE p() BEGIN SELECT 1; SELECT 2; END",
            "INSERT INTO t VALUES (1)",
        ])
    }

    @Test func quotesEscapesAndVersionComments() {
        let script = #"""
        /*!40101 SET NAMES utf8mb4 */;
        INSERT INTO t VALUES ('it\'s; fine', "x;y", `odd;name`);
        SELECT '--not a comment' /* inline; comment */ FROM dual;
        """#
        #expect(MySQLScript.statements(script) == [
            "/*!40101 SET NAMES utf8mb4 */",
            #"INSERT INTO t VALUES ('it\'s; fine', "x;y", `odd;name`)"#,
            "SELECT '--not a comment' /* inline; comment */ FROM dual",
        ])
    }

    @Test func emptyStatementsAreDropped() {
        #expect(MySQLScript.statements(";;\n  ;\n-- only a comment\n") == [])
    }
}
