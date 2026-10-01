import Testing
@testable import MySQLKit
import MySQLWire

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

@Suite struct MySQLUserSQLTests {
    let security = MySQLClient(configuration: MySQLConfiguration(host: "localhost", username: "root")).security

    @Test func passwordWithoutPluginIsIdentifiedBy() {
        #expect(security.createUserSQL(username: "app", host: "%", password: "p'w", authenticationPlugin: nil)
                == "CREATE USER 'app'@'%' IDENTIFIED BY 'p''w'")
        #expect(security.createUserSQL(username: "app", host: "%", password: "pw", authenticationPlugin: "caching_sha2_password")
                == "CREATE USER 'app'@'%' IDENTIFIED WITH caching_sha2_password BY 'pw'")
        #expect(security.createUserSQL(username: "app", host: "%", password: nil, authenticationPlugin: nil) == "CREATE USER 'app'@'%'")
    }

    @Test func mariaDBPluginPasswordUsesVia() {
        #expect(security.createUserSQL(username: "app", host: "%", password: "pw", authenticationPlugin: "ed25519", mariaDB: true)
                == "CREATE USER 'app'@'%' IDENTIFIED VIA ed25519 USING PASSWORD('pw')")
        #expect(security.createUserSQL(username: "app", host: "%", password: "pw", authenticationPlugin: nil, mariaDB: true)
                == "CREATE USER 'app'@'%' IDENTIFIED BY 'pw'")
    }

    @Test func tlsRequirementClauses() {
        #expect(MySQLTLSRequirement.x509.clause == " REQUIRE X509")
        #expect(MySQLTLSRequirement.subject("/CN=o'k").clause == " REQUIRE SUBJECT '/CN=o''k'")
        #expect(MySQLTLSRequirement.none.clause == "")
    }

    @Test func pluginInstallNamesItsLibrary() {
        #expect(security.installPluginSQL(name: "ed25519", library: "auth_ed25519")
                == "INSTALL PLUGIN `ed25519` SONAME 'auth_ed25519'")
    }

    @Test func rolesNeedNoHost() {
        #expect(security.roleName("lab_reader", host: nil) == "'lab_reader'")
        #expect(security.roleName("lab_reader", host: "%") == "'lab_reader'@'%'")
    }
}

@Suite struct MySQLPartitionAndSequenceSQLTests {
    @Test func partitioningClauses() {
        let range = MySQLTableSQL.createTable(schema: "s", name: "sales", columns: [MySQLColumnDefinition(name: "y", dataType: "INT")], primaryKey: [],
                                              options: .init(partitioning: .range(expression: "`y`", partitions: [("p2024", "2025"), ("pmax", nil)])), ifNotExists: false)
        #expect(range.hasSuffix("PARTITION BY RANGE (`y`) (PARTITION `p2024` VALUES LESS THAN (2025), PARTITION `pmax` VALUES LESS THAN MAXVALUE)"))
        #expect(MySQLPartitioning.list(expression: "`r`", partitions: [("north", ["1", "2"])]).sql == "PARTITION BY LIST (`r`) (PARTITION `north` VALUES IN (1, 2))")
        #expect(MySQLPartitioning.key(columns: ["id"], count: 4).sql == "PARTITION BY KEY (`id`) PARTITIONS 4")
    }

    @Test func sequences() {
        #expect(MySQLTableSQL.createSequence(schema: "s", name: "seq", start: 100, increment: 5, minValue: 1, maxValue: nil, cache: 10, cycle: true)
                == "CREATE SEQUENCE `s`.`seq` START WITH 100 INCREMENT BY 5 MINVALUE 1 NO MAXVALUE CACHE 10 CYCLE")
    }
}

@Suite struct MySQLUpdateDeleteSQLTests {
    @Test func equalityConditionsAreBound() {
        let (update, binds) = MySQLTableSQL.update(schema: "s", table: "t", set: ["price": .data(MySQLData(string: "2.00"))], where: ["sku": .data(MySQLData(string: "A"))])
        #expect(update == "UPDATE `s`.`t` SET `price` = ? WHERE `sku` = ?")
        #expect(binds.count == 2)
        #expect(MySQLTableSQL.delete(schema: "s", table: "t", where: ["a": .null, "b": .data(MySQLData(int: 1))]).0 == "DELETE FROM `s`.`t` WHERE `a` = ? AND `b` = ?")
    }
}

@Suite struct MySQLServerStatementSQLTests {
    @Test func variablePatternIsALiteral() {
        #expect(MySQLServerConfigClient.globalVariablesSQL(named: "sql_mode") == "SHOW GLOBAL VARIABLES LIKE 'sql_mode'")
        #expect(MySQLServerConfigClient.globalVariablesSQL(named: "it's") == "SHOW GLOBAL VARIABLES LIKE 'it''s'")
        #expect(MySQLServerConfigClient.globalVariablesSQL(named: nil) == "SHOW GLOBAL VARIABLES")
    }

    @Test func slowLogOrdersByStartTime() {
        #expect(MySQLErrorLogClient.tableLogSQL(named: "slow_log", limit: 5) == "SELECT * FROM mysql.`slow_log` ORDER BY start_time DESC LIMIT 5")
        #expect(MySQLErrorLogClient.tableLogSQL(named: "general_log", limit: 5) == "SELECT * FROM mysql.`general_log` ORDER BY event_time DESC LIMIT 5")
    }
}
