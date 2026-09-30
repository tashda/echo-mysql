import Testing
@testable import MySQLKit

@Suite struct MySQLTableSQLTests {
    @Test func columnsCarryEveryAttribute() {
        let sql = MySQLTableSQL.createTable(schema: "labdata", name: "items", columns: [
            MySQLColumnDefinition(name: "id", dataType: "BIGINT UNSIGNED", isNullable: false, isAutoIncrement: true),
            MySQLColumnDefinition(name: "name", dataType: "VARCHAR(50)", defaultValue: .string("it's"), characterSet: "utf8mb4",
                                  collation: "utf8mb4_bin", comment: "label"),
            MySQLColumnDefinition(name: "created", dataType: "DATETIME(6)", isNullable: false, defaultValue: .currentTimestamp(precision: 6)),
            MySQLColumnDefinition(name: "total", dataType: "DECIMAL(10,2)", generated: .init(expression: "`id` * 2", isStored: true)),
            MySQLColumnDefinition(name: "place", dataType: "POINT", isNullable: false, srid: 4326),
            MySQLColumnDefinition(name: "token", dataType: "CHAR(36)", defaultValue: .expression("UUID()"), isInvisible: true),
        ], primaryKey: ["id"], options: .init(engine: "InnoDB", characterSet: "utf8mb4", comment: "lab"), ifNotExists: false)
        #expect(sql.hasPrefix("CREATE TABLE `labdata`.`items` (`id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT, "))
        #expect(sql.contains("`name` VARCHAR(50) CHARACTER SET utf8mb4 COLLATE utf8mb4_bin NULL DEFAULT 'it''s' COMMENT 'label'"))
        #expect(sql.contains("`created` DATETIME(6) NOT NULL DEFAULT CURRENT_TIMESTAMP(6)"))
        #expect(sql.contains("`total` DECIMAL(10,2) GENERATED ALWAYS AS (`id` * 2) STORED"))
        #expect(sql.contains("`place` POINT NOT NULL SRID 4326"))
        #expect(sql.contains("`token` CHAR(36) NULL DEFAULT (UUID()) INVISIBLE"))
        #expect(sql.hasSuffix("PRIMARY KEY (`id`)) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4 COMMENT='lab'"))
    }

    @Test func indexesAndKeys() {
        #expect(MySQLTableSQL.createIndex(schema: "s", table: "t", name: "ix", columns: [MySQLIndexColumn("a", prefixLength: 10), MySQLIndexColumn("b", isDescending: true)],
                                          kind: .unique, isInvisible: true, comment: nil)
                == "CREATE UNIQUE INDEX `ix` ON `s`.`t` (`a`(10), `b` DESC) INVISIBLE")
        #expect(MySQLTableSQL.addForeignKey(schema: "s", table: "t", name: "fk", columns: ["a"], referencedSchema: "s", referencedTable: "p",
                                            referencedColumns: ["id"], onDelete: .cascade, onUpdate: nil)
                == "ALTER TABLE `s`.`t` ADD CONSTRAINT `fk` FOREIGN KEY (`a`) REFERENCES `s`.`p` (`id`) ON DELETE CASCADE")
    }

    @Test func insertWrapsTypedValues() {
        let sql = MySQLTableSQL.insert(schema: "s", table: "t", columns: ["g", "j", "v", "n"],
                                       row: [.geometry(wkt: "POINT(1 2)", srid: 4326), .json("{}"), .vector([1, 2]), .null])
        #expect(sql == "INSERT INTO `s`.`t` (`g`, `j`, `v`, `n`) VALUES (ST_GeomFromText(?, 4326), CAST(? AS JSON), STRING_TO_VECTOR(?), ?)")
    }
}
