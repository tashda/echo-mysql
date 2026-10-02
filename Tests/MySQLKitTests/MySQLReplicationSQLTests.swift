import Testing
@testable import MySQLKit

@Suite struct MySQLReplicationSQLTests {
    @Test func keywordsFollowTheServer() {
        let mysql84 = MySQLReplicationClient.ServerFlavor(version: "8.4.11")
        let mysql80old = MySQLReplicationClient.ServerFlavor(version: "8.0.22-log")
        let mariadb = MySQLReplicationClient.ServerFlavor(version: "11.4.5-MariaDB-ubu2404")
        #expect(mysql84.usesReplicaKeywords && !mysql80old.usesReplicaKeywords && !mariadb.usesReplicaKeywords && mariadb.isMariaDB)
        #expect(MySQLReplicationClient.configureSourceSQL(flavor: mysql84, host: "primary", port: 3306, user: "repl", password: "p'w",
                                                          useTLS: false, getSourcePublicKey: true)
                == "CHANGE REPLICATION SOURCE TO SOURCE_HOST = 'primary', SOURCE_PORT = 3306, SOURCE_USER = 'repl', SOURCE_PASSWORD = 'p''w', SOURCE_SSL = 0, SOURCE_AUTO_POSITION = 1, GET_SOURCE_PUBLIC_KEY = 1")
        #expect(MySQLReplicationClient.configureSourceSQL(flavor: mariadb, host: "primary", port: 3306, user: "repl", password: "pw",
                                                          useTLS: true, getSourcePublicKey: true).hasSuffix("MASTER_SSL = 1, MASTER_USE_GTID = slave_pos"))
    }
}
