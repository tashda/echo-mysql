import Logging
import Testing
@testable import MySQLKit

actor MockConnectionSession: MySQLConnectionSession {
    private(set) var simpleQueries: [String] = []
    private(set) var changedDatabases: [String] = []
    private(set) var preparedQueries: [(sql: String, binds: [String?])] = []
    private(set) var validateCalls = 0
    private(set) var closeCalls = 0
    private let databaseName: String?
    private let simpleQueryResults: [String: [MySQLRow]]
    private let preparedQueryResults: [String: MySQLWireQueryResult]

    init(
        databaseName: String? = "echo",
        simpleQueryResults: [String: [MySQLRow]] = [:],
        preparedQueryResults: [String: MySQLWireQueryResult] = [:]
    ) {
        self.databaseName = databaseName
        self.simpleQueryResults = simpleQueryResults
        self.preparedQueryResults = preparedQueryResults
    }

    func simpleQuery(_ sql: String) async throws -> [MySQLRow] {
        simpleQueries.append(sql)
        return simpleQueryResults[sql, default: []]
    }

    func query(_ sql: String, binds: [MySQLData]) async throws -> MySQLWireQueryResult {
        preparedQueries.append((sql, binds.map(\.string)))
        return preparedQueryResults[sql, default: MySQLWireQueryResult(rows: [], metadata: nil)]
    }

    func stream(_ sql: String) async throws -> MySQLRowStream {
        simpleQueries.append(sql)
        return MySQLRowStream(rows: [])
    }

    func changeDatabase(_ database: String) async throws {
        changedDatabases.append(database)
    }

    func currentDatabase() async throws -> String? {
        databaseName
    }

    func validate() async throws {
        validateCalls += 1
    }

    func close() async {
        closeCalls += 1
    }
}

actor ConnectionFactoryCounter {
    private var value = 0

    func next() -> Int {
        value += 1
        return value
    }

    func current() -> Int {
        value
    }
}

struct MySQLClientTests {
    @Test
    func namespacesUseExpectedConnections() async throws {
        let primary = MockConnectionSession(databaseName: "primary_db")
        let metadata = MockConnectionSession(databaseName: "metadata_db")
        let counter = ConnectionFactoryCounter()

        let serverConnection = MySQLServerConnection(
            configuration: MySQLConfiguration(host: "localhost", username: "root"),
            logger: Logger(label: "tests.mysql-kit"),
            connectionFactory: { _, _ in
                let createdConnections = await counter.next()
                return createdConnections == 1 ? primary : metadata
            }
        )
        let client = MySQLClient(
            configuration: MySQLConfiguration(host: "localhost", username: "root"),
            serverConnection: serverConnection
        )

        _ = try await client.simpleQuery("SELECT 1")
        _ = try await client.metadata.listDatabases()
        let currentDatabase = try await client.metadata.currentDatabase()
        try await client.metadata.selectDatabase("analytics")

        #expect(await counter.current() == 2)
        #expect(currentDatabase == "primary_db")
        #expect(await primary.simpleQueries == ["SELECT 1"])
        #expect(await metadata.simpleQueries == ["SHOW DATABASES"])
        #expect(await primary.changedDatabases == ["analytics"])
    }

    @Test
    func metadataQueriesReturnTypedResults() async throws {
        let tablesSQL = """
        SELECT
            table_name,
            table_type
        FROM information_schema.tables
        WHERE table_schema = ?
        ORDER BY table_name;
        """
        let columnsSQL = """
        SELECT
            column_name,
            data_type,
            column_type,
            is_nullable,
            column_key,
            character_maximum_length,
            column_default,
            generation_expression,
            extra,
            collation_name,
            character_set_name,
            column_comment,
            ordinal_position
        FROM information_schema.columns
        WHERE table_schema = ? AND table_name = ?
        ORDER BY ordinal_position;
        """
        let tableOptionsSQL = """
        SELECT
            engine,
            SUBSTRING_INDEX(table_collation, '_', 1) AS character_set_name,
            table_collation,
            auto_increment,
            row_format,
            table_comment,
            table_rows,
            data_length,
            index_length
        FROM information_schema.tables
        WHERE table_schema = ? AND table_name = ?;
        """

        let metadata = MockConnectionSession(
            databaseName: "sakila",
            simpleQueryResults: [
                "SHOW CREATE TABLE `sakila`.`actor`": [
                    Self.textRow([
                        ("Table", "actor"),
                        ("Create Table", "CREATE TABLE `actor` (`actor_id` int NOT NULL)")
                    ])
                ]
            ],
            preparedQueryResults: [
                tablesSQL: MySQLWireQueryResult(
                    rows: [
                        Self.textRow([("table_name", "actor"), ("table_type", "BASE TABLE")]),
                        Self.textRow([("table_name", "actor_info"), ("table_type", "VIEW")])
                    ],
                    metadata: nil
                ),
                columnsSQL: MySQLWireQueryResult(
                    rows: [
                        Self.textRow([
                            ("column_name", "actor_id"),
                            ("data_type", "int"),
                            ("column_type", "int"),
                            ("is_nullable", "NO"),
                            ("column_key", "PRI"),
                            ("character_maximum_length", nil),
                            ("column_default", nil),
                            ("generation_expression", nil),
                            ("extra", "auto_increment"),
                            ("collation_name", nil),
                            ("character_set_name", nil),
                            ("column_comment", nil),
                            ("ordinal_position", "1")
                        ]),
                        Self.textRow([
                            ("column_name", "first_name"),
                            ("data_type", "varchar"),
                            ("column_type", "varchar(45)"),
                            ("is_nullable", "NO"),
                            ("column_key", ""),
                            ("character_maximum_length", "45"),
                            ("column_default", nil),
                            ("generation_expression", nil),
                            ("extra", ""),
                            ("collation_name", "utf8mb4_0900_ai_ci"),
                            ("character_set_name", "utf8mb4"),
                            ("column_comment", "given name"),
                            ("ordinal_position", "2")
                        ])
                    ],
                    metadata: nil
                ),
                tableOptionsSQL: MySQLWireQueryResult(
                    rows: [
                        Self.textRow([
                            ("engine", "InnoDB"),
                            ("character_set_name", "utf8mb4"),
                            ("table_collation", "utf8mb4_0900_ai_ci"),
                            ("auto_increment", "201"),
                            ("row_format", "Dynamic"),
                            ("table_comment", "actor details"),
                            ("table_rows", "200"),
                            ("data_length", "16384"),
                            ("index_length", "8192")
                        ])
                    ],
                    metadata: nil
                )
            ]
        )
        let counter = ConnectionFactoryCounter()

        let client = MySQLClient(
            configuration: MySQLConfiguration(host: "localhost", username: "root", database: "sakila"),
            serverConnection: MySQLServerConnection(
                configuration: MySQLConfiguration(host: "localhost", username: "root", database: "sakila"),
                logger: Logger(label: "tests.mysql-kit.metadata"),
                connectionFactory: { _, _ in
                    _ = await counter.next()
                    return metadata
                }
            )
        )

        let objects = try await client.metadata.listTablesAndViews(in: "sakila")
        let columns = try await client.metadata.listColumns(in: "actor", schema: "sakila")
        let options = try await client.metadata.tableOptions(for: "actor", schema: "sakila")
        let definition = try await client.metadata.objectDefinition(named: "actor", schema: "sakila", kind: .table)

        #expect(objects.map(\.name) == ["actor", "actor_info"])
        #expect(objects.map(\.kind) == [.table, .view])
        #expect(columns.map(\.name) == ["actor_id", "first_name"])
        #expect(columns.first?.isPrimaryKey == true)
        #expect(columns.first?.isAutoIncrement == true)
        #expect(columns.last?.fullDataType == "varchar(45)")
        #expect(columns.last?.maxLength == 45)
        #expect(columns.last?.collation == "utf8mb4_0900_ai_ci")
        #expect(options?.engine == "InnoDB")
        #expect(options?.characterSet == "utf8mb4")
        #expect(options?.autoIncrement == 201)
        #expect(options?.estimatedRowCount == 200)
        #expect(options?.dataLength == 16_384)
        #expect(definition.contains("CREATE TABLE `actor`"))
        #expect(await counter.current() == 1)
        #expect(await metadata.preparedQueries.count == 3)
    }

    @Test
    func securityRolesReturnTypedResults() async throws {
        let metadata = MockConnectionSession(
            simpleQueryResults: [
                "SELECT DISTINCT FROM_USER AS role_name, FROM_HOST AS role_host FROM mysql.role_edges ORDER BY FROM_USER, FROM_HOST": [
                    Self.textRow([("role_name", "app_readonly"), ("role_host", "%")]),
                    Self.textRow([("role_name", "app_admin"), ("role_host", "%")])
                ],
                "SELECT FROM_USER AS role_name, FROM_HOST AS role_host, TO_USER AS to_user, TO_HOST AS to_host FROM mysql.role_edges ORDER BY TO_USER, FROM_USER": [
                    Self.textRow([("role_name", "app_readonly"), ("role_host", "%"), ("to_user", "echo"), ("to_host", "%")])
                ]
            ]
        )

        let client = MySQLClient(
            configuration: MySQLConfiguration(host: "localhost", username: "root"),
            serverConnection: MySQLServerConnection(
                configuration: MySQLConfiguration(host: "localhost", username: "root"),
                logger: Logger(label: "tests.mysql-kit.security"),
                connectionFactory: { _, _ in metadata }
            )
        )

        let roles = try await client.security.listRoles()
        let assignments = try await client.security.listRoleAssignments()

        #expect(roles.map(\.name) == ["app_readonly", "app_admin"])
        #expect(assignments.count == 1)
        #expect(assignments.first?.roleName == "app_readonly")
        #expect(assignments.first?.grantee == "'echo'@'%'")
    }

    @Test
    func tableStructureAggregatesMetadataQueries() async throws {
        let columnsSQL = """
        SELECT
            column_name,
            data_type,
            column_type,
            is_nullable,
            column_key,
            character_maximum_length,
            column_default,
            generation_expression,
            extra,
            collation_name,
            character_set_name,
            column_comment,
            ordinal_position
        FROM information_schema.columns
        WHERE table_schema = ? AND table_name = ?
        ORDER BY ordinal_position;
        """
        let primaryKeySQL = """
        SELECT k.constraint_name, k.column_name
        FROM information_schema.table_constraints t
        JOIN information_schema.key_column_usage k
          ON k.constraint_name = t.constraint_name
         AND k.table_schema = t.table_schema
         AND k.table_name = t.table_name
        WHERE t.table_schema = ?
          AND t.table_name = ?
          AND t.constraint_type = 'PRIMARY KEY'
        ORDER BY k.ordinal_position;
        """
        let indexesSQL = """
        SELECT
            index_name,
            non_unique,
            seq_in_index,
            column_name,
            collation,
            index_type
        FROM information_schema.statistics
        WHERE table_schema = ? AND table_name = ?
        ORDER BY index_name, seq_in_index;
        """
        let foreignKeysSQL = """
        SELECT
            rc.constraint_name,
            kcu.column_name,
            kcu.referenced_table_schema,
            kcu.referenced_table_name,
            kcu.referenced_column_name,
            rc.update_rule,
            rc.delete_rule,
            kcu.ordinal_position
        FROM information_schema.referential_constraints rc
        JOIN information_schema.key_column_usage kcu
          ON rc.constraint_name = kcu.constraint_name
         AND rc.constraint_schema = kcu.constraint_schema
        WHERE rc.constraint_schema = ?
          AND rc.table_name = ?
        ORDER BY rc.constraint_name, kcu.ordinal_position;
        """
        let dependenciesSQL = """
        SELECT
            kcu.constraint_name,
            kcu.column_name,
            kcu.referenced_table_name,
            kcu.referenced_column_name,
            rc.update_rule,
            rc.delete_rule
        FROM information_schema.key_column_usage kcu
        JOIN information_schema.referential_constraints rc
          ON rc.constraint_name = kcu.constraint_name
         AND rc.constraint_schema = kcu.constraint_schema
        WHERE kcu.referenced_table_schema = ?
          AND kcu.referenced_table_name = ?
        ORDER BY kcu.constraint_name, kcu.ordinal_position;
        """

        let metadata = MockConnectionSession(
            databaseName: "sakila",
            preparedQueryResults: [
                columnsSQL: MySQLWireQueryResult(
                    rows: [
                        Self.textRow([
                            ("column_name", "actor_id"),
                            ("data_type", "int"),
                            ("column_type", "int"),
                            ("is_nullable", "NO"),
                            ("column_key", "PRI"),
                            ("character_maximum_length", nil),
                            ("column_default", nil),
                            ("generation_expression", nil),
                            ("extra", "auto_increment"),
                            ("collation_name", nil),
                            ("character_set_name", nil),
                            ("column_comment", nil),
                            ("ordinal_position", "1")
                        ])
                    ],
                    metadata: nil
                ),
                primaryKeySQL: MySQLWireQueryResult(
                    rows: [Self.textRow([("constraint_name", "PRIMARY"), ("column_name", "actor_id")])],
                    metadata: nil
                ),
                indexesSQL: MySQLWireQueryResult(
                    rows: [
                        Self.textRow([
                            ("index_name", "idx_last_name"),
                            ("non_unique", "1"),
                            ("seq_in_index", "1"),
                            ("column_name", "last_name"),
                            ("collation", "A"),
                            ("index_type", "BTREE")
                        ])
                    ],
                    metadata: nil
                ),
                foreignKeysSQL: MySQLWireQueryResult(
                    rows: [
                        Self.textRow([
                            ("constraint_name", "fk_actor_film"),
                            ("column_name", "actor_id"),
                            ("referenced_table_schema", "sakila"),
                            ("referenced_table_name", "film_actor"),
                            ("referenced_column_name", "actor_id"),
                            ("update_rule", "CASCADE"),
                            ("delete_rule", "CASCADE"),
                            ("ordinal_position", "1")
                        ])
                    ],
                    metadata: nil
                ),
                dependenciesSQL: MySQLWireQueryResult(
                    rows: [
                        Self.textRow([
                            ("constraint_name", "fk_film_actor_actor"),
                            ("column_name", "actor_id"),
                            ("referenced_table_name", "film_actor"),
                            ("referenced_column_name", "actor_id"),
                            ("update_rule", "CASCADE"),
                            ("delete_rule", "CASCADE")
                        ])
                    ],
                    metadata: nil
                )
            ]
        )

        let client = MySQLClient(
            configuration: MySQLConfiguration(host: "localhost", username: "root", database: "sakila"),
            serverConnection: MySQLServerConnection(
                configuration: MySQLConfiguration(host: "localhost", username: "root", database: "sakila"),
                logger: Logger(label: "tests.mysql-kit.structure"),
                connectionFactory: { _, _ in metadata }
            )
        )

        let structure = try await client.metadata.tableStructure(for: "actor", schema: "sakila")

        #expect(structure.columns.map(\.name) == ["actor_id"])
        #expect(structure.columns.first?.isAutoIncrement == true)
        #expect(structure.primaryKey?.name == "PRIMARY")
        #expect(structure.indexes.map(\.name) == ["idx_last_name"])
        #expect(structure.indexes.first?.indexType == "BTREE")
        #expect(structure.foreignKeys.map(\.name) == ["fk_actor_film"])
        #expect(structure.dependencies.map(\.name) == ["fk_film_actor_actor"])
        #expect(await metadata.preparedQueries.count == 5)
    }

    @Test
    func adminUsesActivityAndDedicatedConnections() async throws {
        let primary = MockConnectionSession(
            simpleQueryResults: [
                "ANALYZE TABLE `sakila`.`actor`": [Self.textRow([("Msg_text", "OK")])]
            ]
        )
        let activity = MockConnectionSession(
            preparedQueryResults: [
                "SHOW GLOBAL STATUS": MySQLWireQueryResult(
                    rows: [Self.textRow([("Variable_name", "Threads_connected"), ("Value", "12")])],
                    metadata: nil
                ),
                "SHOW GLOBAL VARIABLES LIKE 'max_connections'": MySQLWireQueryResult(
                    rows: [Self.textRow([("Variable_name", "max_connections"), ("Value", "151")])],
                    metadata: nil
                ),
                "SHOW FULL PROCESSLIST": MySQLWireQueryResult(
                    rows: [
                        Self.textRow([
                            ("Id", "42"),
                            ("User", "echo"),
                            ("Host", "localhost:51234"),
                            ("db", "sakila"),
                            ("Command", "Query"),
                            ("Time", "3"),
                            ("State", "executing"),
                            ("Info", "SELECT 1")
                        ])
                    ],
                    metadata: nil
                )
            ]
        )
        let cancel = MockConnectionSession()
        let counter = ConnectionFactoryCounter()

        let serverConnection = MySQLServerConnection(
            configuration: MySQLConfiguration(host: "localhost", username: "root", database: "sakila"),
            logger: Logger(label: "tests.mysql-kit.admin"),
            connectionFactory: { _, _ in
                let index = await counter.next()
                switch index {
                case 1: return activity
                case 2: return cancel
                default: return primary
                }
            }
        )
        let client = MySQLClient(
            configuration: MySQLConfiguration(host: "localhost", username: "root", database: "sakila"),
            serverConnection: serverConnection
        )

        let status = try await client.serverConfig.globalStatus()
        let variables = try await client.serverConfig.globalVariables(named: "max_connections")
        let processes = try await client.activity.processList()
        try await client.activity.killQuery(threadID: 42)
        let maintenance = try await client.maintenance.analyzeTable(schema: "sakila", table: "actor")
        try await serverConnection.ping()
        await serverConnection.close()

        #expect(status.first?.name == "Threads_connected")
        #expect(variables.first?.value == "151")
        #expect(processes.first?.id == 42)
        #expect(maintenance.messages == ["OK"])
        #expect(await cancel.simpleQueries == ["KILL QUERY 42"])
        #expect(await cancel.closeCalls == 1)
        #expect(await primary.validateCalls == 1)
        #expect(await activity.validateCalls == 1)
        #expect(await primary.closeCalls == 1)
        #expect(await activity.closeCalls == 1)
    }

    @Test
    func securityReturnsUsersAndGrants() async throws {
        let listUsersSQL = MySQLSecurityClient.mysqlUsersSQL

        let metadata = MockConnectionSession(
            simpleQueryResults: [
                "SHOW GRANTS FOR 'echo'@'localhost'": [
                    Self.textRow([("Grants for echo@localhost", "GRANT ALL PRIVILEGES ON *.* TO `echo`@`localhost`")])
                ]
            ],
            preparedQueryResults: [
                listUsersSQL: MySQLWireQueryResult(
                    rows: [
                        Self.textRow([
                            ("User", "echo"),
                            ("Host", "localhost"),
                            ("plugin", "caching_sha2_password"),
                            ("account_locked", "N"),
                            ("password_expired", "N")
                        ]),
                        Self.textRow([
                            ("User", "reporter"),
                            ("Host", "%"),
                            ("plugin", "mysql_native_password"),
                            ("account_locked", "Y"),
                            ("password_expired", "N")
                        ])
                    ],
                    metadata: nil
                )
            ]
        )

        let client = MySQLClient(
            configuration: MySQLConfiguration(host: "localhost", username: "root"),
            serverConnection: MySQLServerConnection(
                configuration: MySQLConfiguration(host: "localhost", username: "root"),
                logger: Logger(label: "tests.mysql-kit.security"),
                connectionFactory: { _, _ in metadata }
            )
        )

        let users = try await client.security.listUsers()
        let grants = try await client.security.showGrants(for: "echo", host: "localhost")

        #expect(users.map(\.username) == ["echo", "reporter"])
        #expect(users.last?.accountLocked == true)
        #expect(grants == ["GRANT ALL PRIVILEGES ON *.* TO `echo`@`localhost`"])
        #expect(await metadata.preparedQueries.count == 1)
        // listUsers asks the server's version first (MariaDB keeps accounts elsewhere).
        #expect(await metadata.simpleQueries == ["SELECT VERSION() AS version", "SHOW GRANTS FOR 'echo'@'localhost'"])
    }

    @Test
    func securityReturnsSchemaPrivileges() async throws {
        let schemaPrivilegesSQL = """
        SELECT
            grantee,
            table_schema,
            privilege_type,
            is_grantable
        FROM information_schema.schema_privileges
        ORDER BY grantee, table_schema, privilege_type;
        """

        let metadata = MockConnectionSession(
            preparedQueryResults: [
                schemaPrivilegesSQL: MySQLWireQueryResult(
                    rows: [
                        Self.textRow([
                            ("grantee", "'echo'@'%'"),
                            ("table_schema", "sakila"),
                            ("privilege_type", "SELECT"),
                            ("is_grantable", "YES")
                        ]),
                        Self.textRow([
                            ("grantee", "'reporter'@'%'"),
                            ("table_schema", "sakila"),
                            ("privilege_type", "EXECUTE"),
                            ("is_grantable", "NO")
                        ])
                    ],
                    metadata: nil
                )
            ]
        )

        let client = MySQLClient(
            configuration: MySQLConfiguration(host: "localhost", username: "root"),
            serverConnection: MySQLServerConnection(
                configuration: MySQLConfiguration(host: "localhost", username: "root"),
                logger: Logger(label: "tests.mysql-kit.security.schema"),
                connectionFactory: { _, _ in metadata }
            )
        )

        let grants = try await client.security.schemaPrivileges()

        #expect(grants.count == 2)
        #expect(grants.first?.tableSchema == "sakila")
        #expect(grants.first?.tableName == nil)
        #expect(grants.first?.isGrantable == true)
    }

    @Test
    func transactionClientUsesPrimaryConnection() async throws {
        let primary = MockConnectionSession(
            simpleQueryResults: [
                "SHOW BINARY LOG STATUS": [
                    Self.textRow([
                        ("File", "binlog.000001"),
                        ("Position", "157")
                    ])
                ]
            ]
        )
        let client = MySQLClient(
            configuration: MySQLConfiguration(host: "localhost", username: "root"),
            serverConnection: MySQLServerConnection(
                configuration: MySQLConfiguration(host: "localhost", username: "root"),
                logger: Logger(label: "tests.mysql-kit.transaction"),
                connectionFactory: { _, _ in primary }
            )
        )

        try await client.transactions.begin()
        try await client.transactions.commit()
        do {
            _ = try await client.transactions.withTransaction {
                struct Expected: Error {}
                throw Expected()
            }
        } catch {}

        #expect(await primary.simpleQueries == [
            "START TRANSACTION",
            "COMMIT",
            "START TRANSACTION",
            "ROLLBACK"
        ])
    }

    @Test
    func activityAndPerformanceUseExpectedSurfaces() async throws {
        let primary = MockConnectionSession(
            simpleQueryResults: [
                "EXPLAIN SELECT * FROM actor": [
                    Self.textRow([
                        ("id", "1"),
                        ("select_type", "SIMPLE"),
                        ("table", "actor")
                    ])
                ],
                "EXPLAIN FORMAT=JSON SELECT * FROM actor": [
                    Self.textRow([("EXPLAIN", #"{"query_block":{"select_id":1,"cost_info":{"query_cost":"1.00"},"table":{"table_name":"actor","access_type":"ALL","rows_examined_per_scan":200,"rows_produced_per_join":200,"used_columns":["actor_id"]}}}"#)])
                ],
                "EXPLAIN ANALYZE SELECT * FROM actor": [
                    Self.textRow([("EXPLAIN", "-> Table scan on actor  (cost=1.00 rows=200) (actual time=0.010..0.020 rows=200 loops=1)")])
                ]
            ]
        )
        let activity = MockConnectionSession(
            preparedQueryResults: [
                "SHOW FULL PROCESSLIST": MySQLWireQueryResult(
                    rows: [
                        Self.textRow([
                            ("Id", "7"),
                            ("User", "echo"),
                            ("Host", "localhost:1234"),
                            ("db", "sakila"),
                            ("Command", "Query"),
                            ("Time", "1"),
                            ("State", "running"),
                            ("Info", "SELECT * FROM actor")
                        ])
                    ],
                    metadata: nil
                ),
                "SHOW GLOBAL STATUS": MySQLWireQueryResult(
                    rows: [Self.textRow([("Variable_name", "Questions"), ("Value", "99")])],
                    metadata: nil
                )
            ]
        )
        let counter = ConnectionFactoryCounter()
        let client = MySQLClient(
            configuration: MySQLConfiguration(host: "localhost", username: "root"),
            serverConnection: MySQLServerConnection(
                configuration: MySQLConfiguration(host: "localhost", username: "root"),
                logger: Logger(label: "tests.mysql-kit.activity"),
                connectionFactory: { _, _ in
                    let index = await counter.next()
                    return index == 1 ? primary : activity
                }
            )
        )

        let explain = try await client.executionPlan.explain("SELECT * FROM actor")
        let explainJSON = try await client.executionPlan.explainJSON("SELECT * FROM actor")
        let explainAnalyze = try await client.executionPlan.explainAnalyze("SELECT * FROM actor")
        let dashboard = try await client.performance.dashboardStatus()
        let snapshot = try await client.activity.snapshot()

        #expect(explain.rows.first?["table"]??.description == "actor")
        #expect(explainJSON.json.contains("\"query_block\""))
        #expect(explainAnalyze.lines.first?.contains("Table scan on actor") == true)
        #expect(dashboard.first?.name == "Questions")
        #expect(snapshot.processes.first?.id == 7)
    }

    @Test
    func metadataSecurityAndReplicationCoverage() async throws {
        let routinesSQL = """
        SELECT
            routine_schema,
            routine_name,
            routine_type,
            routine_definition
        FROM information_schema.routines
        WHERE routine_schema = ?
        ORDER BY routine_name;
        """
        let triggersSQL = """
        SELECT
            trigger_schema,
            trigger_name,
            event_object_table,
            action_timing,
            event_manipulation,
            action_statement
        FROM information_schema.triggers
        WHERE trigger_schema = ?
        ORDER BY trigger_name;
        """
        let eventsSQL = """
        SELECT
            event_schema,
            event_name,
            status,
            interval_value,
            interval_field,
            event_definition
        FROM information_schema.events
        WHERE event_schema = ?
        ORDER BY event_name;
        """
        let searchSQL = """
        SELECT object_schema, object_name, object_type
        FROM (
            SELECT table_schema AS object_schema, table_name AS object_name, table_type AS object_type
            FROM information_schema.tables
            WHERE table_name LIKE ?
            UNION ALL
            SELECT routine_schema AS object_schema, routine_name AS object_name, routine_type AS object_type
            FROM information_schema.routines
            WHERE routine_name LIKE ?
            UNION ALL
            SELECT trigger_schema AS object_schema, trigger_name AS object_name, 'TRIGGER' AS object_type
            FROM information_schema.triggers
            WHERE trigger_name LIKE ?
        ) matches
        WHERE 1 = 1
        
        ORDER BY object_schema, object_name;
        """
        let rolesSQL = """
        SELECT
            FROM_USER,
            FROM_HOST,
            TO_USER,
            TO_HOST
        FROM mysql.role_edges
        ORDER BY TO_USER, FROM_USER;
        """
        let privilegesSQL = """
        SELECT
            grantee,
            table_schema,
            table_name,
            privilege_type,
            is_grantable
        FROM information_schema.table_privileges
        ORDER BY grantee, table_schema, table_name, privilege_type;
        """

        let metadata = MockConnectionSession(
            simpleQueryResults: [
                "SHOW REPLICA STATUS": [
                    Self.textRow([
                        ("Replica_IO_Running", "Yes"),
                        ("Replica_SQL_Running", "Yes")
                    ])
                ],
                "SELECT FROM_USER AS role_name, FROM_HOST AS role_host, TO_USER AS to_user, TO_HOST AS to_host FROM mysql.role_edges ORDER BY TO_USER, FROM_USER": [
                    Self.textRow([("role_name", "report_reader"), ("role_host", "%"), ("to_user", "echo"), ("to_host", "%")])
                ]
            ],
            preparedQueryResults: [
                routinesSQL: MySQLWireQueryResult(
                    rows: [Self.textRow([
                        ("routine_schema", "sakila"),
                        ("routine_name", "inventory_in_stock"),
                        ("routine_type", "FUNCTION"),
                        ("routine_definition", "RETURN 1")
                    ])],
                    metadata: nil
                ),
                triggersSQL: MySQLWireQueryResult(
                    rows: [Self.textRow([
                        ("trigger_schema", "sakila"),
                        ("trigger_name", "film_ins"),
                        ("event_object_table", "film"),
                        ("action_timing", "AFTER"),
                        ("event_manipulation", "INSERT"),
                        ("action_statement", "SET @x = 1")
                    ])],
                    metadata: nil
                ),
                eventsSQL: MySQLWireQueryResult(
                    rows: [Self.textRow([
                        ("event_schema", "sakila"),
                        ("event_name", "nightly_refresh"),
                        ("status", "ENABLED"),
                        ("interval_value", "1"),
                        ("interval_field", "DAY"),
                        ("event_definition", "CALL refresh()")
                    ])],
                    metadata: nil
                ),
                searchSQL: MySQLWireQueryResult(
                    rows: [Self.textRow([
                        ("object_schema", "sakila"),
                        ("object_name", "film"),
                        ("object_type", "BASE TABLE")
                    ])],
                    metadata: nil
                ),
                rolesSQL: MySQLWireQueryResult(
                    rows: [Self.textRow([
                        ("FROM_USER", "report_reader"),
                        ("FROM_HOST", "%"),
                        ("TO_USER", "echo"),
                        ("TO_HOST", "localhost")
                    ])],
                    metadata: nil
                ),
                privilegesSQL: MySQLWireQueryResult(
                    rows: [Self.textRow([
                        ("grantee", "'echo'@'localhost'"),
                        ("table_schema", "sakila"),
                        ("table_name", "film"),
                        ("privilege_type", "SELECT"),
                        ("is_grantable", "NO")
                    ])],
                    metadata: nil
                )
            ]
        )

        let client = MySQLClient(
            configuration: MySQLConfiguration(host: "localhost", username: "root", database: "sakila"),
            serverConnection: MySQLServerConnection(
                configuration: MySQLConfiguration(host: "localhost", username: "root", database: "sakila"),
                logger: Logger(label: "tests.mysql-kit.coverage"),
                connectionFactory: { _, _ in metadata }
            )
        )

        let routines = try await client.metadata.listRoutines(in: "sakila")
        let triggers = try await client.metadata.listTriggers(in: "sakila")
        let events = try await client.metadata.listEvents(in: "sakila")
        let searchResults = try await client.metadata.searchObjects(matching: "%film%")
        let roles = try await client.security.listRoleAssignments()
        let privileges = try await client.security.tablePrivileges()
        let replicaStatus = try await client.replication.replicaStatus()

        #expect(routines.first?.name == "inventory_in_stock")
        #expect(triggers.first?.name == "film_ins")
        #expect(events.first?.schedule == "1 DAY")
        #expect(searchResults.first?.name == "film")
        #expect(roles.first?.roleName == "report_reader")
        #expect(privileges.first?.privilegeType == "SELECT")
        #expect(replicaStatus?.rawValues["Replica_IO_Running"]??.description == "Yes")
    }

    @Test
    func adminMutationSecurityMutationAndPerformanceReports() async throws {
        let activity = MockConnectionSession(
            simpleQueryResults: [
                "SELECT * FROM mysql.`general_log` ORDER BY event_time DESC LIMIT 100": [
                    Self.textRow([("event_time", "2026-03-27 08:00:00"), ("argument", "SELECT 1")])
                ],
                """
                SELECT * FROM sys.statement_analysis
                ORDER BY avg_latency DESC
                LIMIT 10
                """: [
                    Self.textRow([("query", "SELECT * FROM actor"), ("avg_latency", "10 ms")])
                ],
                """
                SELECT * FROM sys.schema_unused_indexes
                LIMIT 50
                """: [
                    Self.textRow([("object_schema", "sakila"), ("index_name", "idx_old")])
                ]
            ],
            preparedQueryResults: [
                "SHOW GLOBAL VARIABLES": MySQLWireQueryResult(
                    rows: [
                        Self.textRow([("Variable_name", "general_log_file"), ("Value", "/var/log/mysql/general.log")]),
                        Self.textRow([("Variable_name", "log_output"), ("Value", "TABLE")])
                    ],
                    metadata: nil
                )
            ]
        )
        let primary = MockConnectionSession(
            simpleQueryResults: [
                "SHOW BINARY LOG STATUS": [
                    Self.textRow([
                        ("File", "binlog.000001"),
                        ("Position", "157")
                    ])
                ]
            ]
        )
        let counter = ConnectionFactoryCounter()

        let client = MySQLClient(
            configuration: MySQLConfiguration(host: "localhost", username: "root", database: "sakila"),
            serverConnection: MySQLServerConnection(
                configuration: MySQLConfiguration(host: "localhost", username: "root", database: "sakila"),
                logger: Logger(label: "tests.mysql-kit.mutation"),
                connectionFactory: { _, _ in
                    let index = await counter.next()
                    return index == 1 ? primary : activity
                }
            )
        )

        try await client.admin.renameTable(schema: "sakila", from: "actor_old", to: "actor_new")
        try await client.admin.dropTable(schema: "sakila", name: "actor_tmp")
        let logDestinations = try await client.errorLog.logDestinations()
        let generalLog = try await client.errorLog.readTableLog(named: "general_log")
        let backupCommand = client.backupRestore.backupCommand(
            host: "db.internal",
            port: 3307,
            username: "echo",
            database: "sakila",
            outputPath: "/tmp/sakila.sql"
        )

        _ = try await client.security.createUser(username: "ci", host: "%", password: "secret")
        try await client.security.grant("SELECT", on: "`sakila`.*", to: "ci", host: "%")
        try await client.security.revoke("SELECT", on: "`sakila`.*", from: "ci", host: "%")
        try await client.security.createRole(name: "report_reader")
        try await client.security.dropRole(name: "report_reader")
        _ = try await client.security.dropUser(username: "ci", host: "%")

        let statementAnalysis = try await client.performance.statementAnalysis()
        let unusedIndexes = try await client.performance.unusedIndexes()

        #expect(logDestinations.map(\.kind) == ["general_log_file", "log_output"])
        #expect(generalLog.first?["argument"]??.description == "SELECT 1")
        #expect(backupCommand.first == "mysqldump")
        #expect(statementAnalysis.name == "statement_analysis")
        #expect(unusedIndexes.name == "schema_unused_indexes")
        #expect(await primary.simpleQueries == [
            "RENAME TABLE `sakila`.`actor_old` TO `sakila`.`actor_new`",
            "DROP TABLE IF EXISTS `sakila`.`actor_tmp`",
            "CREATE USER 'ci'@'%' IDENTIFIED BY 'secret'",
            "GRANT SELECT ON `sakila`.* TO 'ci'@'%'",
            "REVOKE SELECT ON `sakila`.* FROM 'ci'@'%'",
            "CREATE ROLE 'report_reader'",
            "DROP ROLE 'report_reader'",
            "DROP USER IF EXISTS 'ci'@'%'"
        ])
    }

    @Test
    func boundQueriesUseTheBinaryProtocol() async throws {
        let sql = "SELECT * FROM actor WHERE actor_id = ? AND first_name = ?"
        let primary = MockConnectionSession(
            preparedQueryResults: [
                sql: MySQLWireQueryResult(rows: [Self.textRow([("actor_id", "7"), ("first_name", "PENELOPE")])], metadata: nil)
            ]
        )
        let client = MySQLClient(
            configuration: MySQLConfiguration(host: "localhost", username: "root"),
            serverConnection: MySQLServerConnection(
                configuration: MySQLConfiguration(host: "localhost", username: "root"),
                connectionFactory: { _, _ in primary }
            )
        )

        let result = try await client.query(sql, binds: [MySQLData(int: 7), MySQLData(string: "PENELOPE")])

        #expect(result.rows.first?.column("actor_id")?.string == "7")
        // The values travel separately from the SQL; nothing is spliced into a statement.
        #expect(await primary.simpleQueries.isEmpty)
        let prepared = await primary.preparedQueries
        #expect(prepared.map(\.sql) == [sql])
        #expect(prepared.first?.binds == ["7", "PENELOPE"])
    }

    @Test
    func adminVariableMutationAndExtendedPerformanceReports() async throws {
        let activity = MockConnectionSession(
            simpleQueryResults: [
                """
                SELECT * FROM sys.statements_with_runtimes_in_95th_percentile
                LIMIT 10
                """: [
                    Self.textRow([("query", "SELECT * FROM actor"), ("avg_latency", "100 ms")])
                ],
                """
                SELECT * FROM sys.statements_with_full_table_scans
                LIMIT 10
                """: [
                    Self.textRow([("query", "SELECT * FROM film_text"), ("rows_examined", "1000")])
                ],
                "SHOW ENGINE INNODB STATUS": [
                    Self.textRow([("Status", "BUFFER POOL AND MEMORY")])
                ],
                """
                SELECT * FROM sys.schema_index_statistics
                LIMIT 50
                """: [
                    Self.textRow([("table_schema", "sakila"), ("index_name", "idx_actor_last_name")])
                ],
                """
                SELECT * FROM sys.schema_table_statistics
                LIMIT 50
                """: [
                    Self.textRow([("table_schema", "sakila"), ("table_name", "actor")])
                ],
                """
                SELECT * FROM sys.waits_global_by_latency
                LIMIT 50
                """: [
                    Self.textRow([("event", "wait/io/file/sql/binlog"), ("total_latency", "10 ms")])
                ],
                """
                SELECT * FROM sys.waits_by_user_by_latency
                LIMIT 50
                """: [
                    Self.textRow([("user", "root"), ("total_latency", "12 ms")])
                ],
                """
                SELECT * FROM sys.host_summary
                LIMIT 50
                """: [
                    Self.textRow([("host", "app.internal"), ("statements", "42")])
                ]
            ]
        )
        let primary = MockConnectionSession(
            simpleQueryResults: [
                "SHOW BINARY LOG STATUS": [
                    Self.textRow([
                        ("File", "binlog.000001"),
                        ("Position", "157")
                    ])
                ]
            ]
        )
        let counter = ConnectionFactoryCounter()

        let client = MySQLClient(
            configuration: MySQLConfiguration(host: "localhost", username: "root"),
            serverConnection: MySQLServerConnection(
                configuration: MySQLConfiguration(host: "localhost", username: "root"),
                connectionFactory: { _, _ in
                    let index = await counter.next()
                    return index == 1 ? primary : activity
                }
            )
        )

        let setResult = try await client.serverConfig.setGlobalVariable("max_connections", to: "200")
        let resetResult = try await client.serverConfig.resetGlobalVariable("max_connections")
        try await client.maintenance.flushTables()
        let restoreCommand = client.backupRestore.restoreCommand(
            host: "db.internal",
            port: 3307,
            username: "echo",
            database: "sakila",
            inputPath: "/tmp/sakila.sql"
        )
        let topRuntime = try await client.performance.topRuntimeStatements()
        let fullTableScans = try await client.performance.fullTableScans()
        let innodbStatus = try await client.performance.innodbStatus()
        let indexStats = try await client.performance.schemaIndexStatistics()
        let tableStats = try await client.performance.schemaTableStatistics()
        let waits = try await client.performance.waitsGlobalByLatency()
        let waitsByUser = try await client.performance.waitsByUserByLatency()
        let hostSummary = try await client.performance.hostSummary()

        #expect(setResult.value == "200")
        #expect(resetResult.value == nil)
        #expect(restoreCommand.first == "mysql")
        #expect(topRuntime.name == "statements_with_runtimes_in_95th_percentile")
        #expect(fullTableScans.name == "statements_with_full_table_scans")
        #expect(innodbStatus.statusText == "BUFFER POOL AND MEMORY")
        #expect(indexStats.name == "schema_index_statistics")
        #expect(tableStats.name == "schema_table_statistics")
        #expect(waits.name == "waits_global_by_latency")
        #expect(waitsByUser.name == "waits_by_user_by_latency")
        #expect(hostSummary.name == "host_summary")
        #expect(await primary.simpleQueries == [
            "SET GLOBAL max_connections = 200",
            "SET GLOBAL max_connections = DEFAULT",
            "FLUSH TABLES"
        ])
    }

    @Test
    func metadataConvenienceSecurityMutationsAndPrimaryReplicationStatus() async throws {
        let tablesSQL = """
        SELECT
            table_name,
            table_type
        FROM information_schema.tables
        WHERE table_schema = ?
        ORDER BY table_name;
        """
        let routinesSQL = """
        SELECT
            routine_schema,
            routine_name,
            routine_type,
            routine_definition
        FROM information_schema.routines
        WHERE routine_schema = ?
        ORDER BY routine_name;
        """

        let metadata = MockConnectionSession(
            simpleQueryResults: [
                "SHOW BINARY LOG STATUS": [
                    Self.textRow([("File", "binlog.000001"), ("Position", "1234")])
                ]
            ],
            preparedQueryResults: [
                tablesSQL: MySQLWireQueryResult(
                    rows: [
                        Self.textRow([("table_name", "actor"), ("table_type", "BASE TABLE")]),
                        Self.textRow([("table_name", "actor_info"), ("table_type", "VIEW")])
                    ],
                    metadata: nil
                ),
                routinesSQL: MySQLWireQueryResult(
                    rows: [
                        Self.textRow([
                            ("routine_schema", "sakila"),
                            ("routine_name", "inventory_in_stock"),
                            ("routine_type", "FUNCTION"),
                            ("routine_definition", "RETURN 1")
                        ]),
                        Self.textRow([
                            ("routine_schema", "sakila"),
                            ("routine_name", "film_in_stock"),
                            ("routine_type", "PROCEDURE"),
                            ("routine_definition", "SELECT 1")
                        ])
                    ],
                    metadata: nil
                )
            ]
        )
        let primary = MockConnectionSession(
            simpleQueryResults: [
                "SHOW BINARY LOG STATUS": [
                    Self.textRow([
                        ("File", "binlog.000001"),
                        ("Position", "157")
                    ])
                ]
            ]
        )
        let counter = ConnectionFactoryCounter()
        let client = MySQLClient(
            configuration: MySQLConfiguration(host: "localhost", username: "root", database: "sakila"),
            serverConnection: MySQLServerConnection(
                configuration: MySQLConfiguration(host: "localhost", username: "root", database: "sakila"),
                connectionFactory: { _, _ in
                    let index = await counter.next()
                    return index == 1 ? metadata : primary
                }
            )
        )

        let tables = try await client.metadata.listTables(in: "sakila")
        let views = try await client.metadata.listViews(in: "sakila")
        let functions = try await client.metadata.listFunctions(in: "sakila")
        let procedures = try await client.metadata.listProcedures(in: "sakila")
        let created = try await client.security.createUser(username: "ops", host: "%", password: "pw")
        let altered = try await client.security.alterUserPassword(username: "ops", host: "%", password: "pw2")
        let locked = try await client.security.lockUser(username: "ops", host: "%")
        let unlocked = try await client.security.unlockUser(username: "ops", host: "%")
        try await client.security.grantRole("report_reader", to: "ops", host: "%")
        try await client.security.revokeRole("report_reader", from: "ops", host: "%")
        try await client.security.setDefaultRole("report_reader", for: "ops", host: "%")
        let primaryStatus = try await client.replication.primaryStatus()

        #expect(tables.map(\.name) == ["actor"])
        #expect(views.map(\.name) == ["actor_info"])
        #expect(functions.map(\.name) == ["inventory_in_stock"])
        #expect(procedures.map(\.name) == ["film_in_stock"])
        #expect(created.operation == "CREATE USER")
        #expect(altered.operation == "ALTER USER PASSWORD")
        #expect(locked.operation == "LOCK USER")
        #expect(unlocked.operation == "UNLOCK USER")
        #expect(primaryStatus?.rawValues["File"] == "binlog.000001")
        #expect(await primary.simpleQueries == [
            "CREATE USER 'ops'@'%' IDENTIFIED BY 'pw'",
            "ALTER USER 'ops'@'%' IDENTIFIED BY 'pw2'",
            "ALTER USER 'ops'@'%' ACCOUNT LOCK",
            "ALTER USER 'ops'@'%' ACCOUNT UNLOCK",
            "GRANT 'report_reader' TO 'ops'@'%'",
            "REVOKE 'report_reader' FROM 'ops'@'%'",
            "SELECT VERSION() AS version",
            "SET DEFAULT ROLE 'report_reader'@'%' TO 'ops'@'%'",
            "SELECT VERSION() AS version",
            "SHOW BINARY LOG STATUS"
        ])
    }

    @Test
    func backslashEscapingFollowsTheSessionSQLMode() async throws {
        func client(sqlMode: String) -> (MySQLClient, MockConnectionSession) {
            let primary = MockConnectionSession(simpleQueryResults: [
                "SELECT @@SESSION.sql_mode AS sql_mode": [Self.textRow([("sql_mode", sqlMode)])]
            ])
            let configuration = MySQLConfiguration(host: "localhost", username: "root")
            let client = MySQLClient(
                configuration: configuration,
                serverConnection: MySQLServerConnection(configuration: configuration, connectionFactory: { _, _ in primary })
            )
            return (client, primary)
        }

        let (standard, standardPrimary) = client(sqlMode: "STRICT_TRANS_TABLES")
        _ = try await standard.security.alterUserPassword(username: "ops", host: "%", password: "plain")
        _ = try await standard.security.alterUserPassword(username: "ops", host: "%", password: "a\\b")
        #expect(await standardPrimary.simpleQueries == [
            "ALTER USER 'ops'@'%' IDENTIFIED BY 'plain'",
            "SELECT @@SESSION.sql_mode AS sql_mode",
            "ALTER USER 'ops'@'%' IDENTIFIED BY 'a\\\\b'"
        ])

        let (noBackslash, noBackslashPrimary) = client(sqlMode: "STRICT_TRANS_TABLES,NO_BACKSLASH_ESCAPES")
        _ = try await noBackslash.security.alterUserPassword(username: "ops", host: "%", password: "a\\b")
        #expect(await noBackslashPrimary.simpleQueries == [
            "SELECT @@SESSION.sql_mode AS sql_mode",
            "ALTER USER 'ops'@'%' IDENTIFIED BY 'a\\b'"
        ])
    }

    @Test
    func sessionAndBulkOperationsUsePrimaryConnection() async throws {
        let twoRowInsertSQL = "INSERT INTO `sakila`.`actor` (`actor_id`, `first_name`) VALUES (?, ?), (?, ?)"
        let oneRowInsertSQL = "INSERT INTO `sakila`.`actor` (`actor_id`, `first_name`) VALUES (?, ?)"

        let primary = MockConnectionSession(
            databaseName: "sakila",
            simpleQueryResults: [
                "SELECT CURRENT_USER() AS account": [
                    Self.textRow([("account", "root@localhost")])
                ],
                "SHOW SESSION VARIABLES": [
                    Self.textRow([("Variable_name", "autocommit"), ("Value", "ON")]),
                    Self.textRow([("Variable_name", "sql_mode"), ("Value", "STRICT_TRANS_TABLES")])
                ],
                "SHOW SESSION VARIABLES WHERE Variable_name IN ('transaction_isolation', 'tx_isolation')": [
                    Self.textRow([("Variable_name", "transaction_isolation"), ("Value", "READ-COMMITTED")])
                ],
                "SET SESSION `sql_mode` = 'ANSI,STRICT_TRANS_TABLES'": [],
                "SET SESSION `optimizer_switch` = DEFAULT": [],
                "SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE": []
            ],
            preparedQueryResults: [
                "SELECT GET_LOCK(?, ?) AS lock_acquired": MySQLWireQueryResult(
                    rows: [Self.textRow([("lock_acquired", "1")])],
                    metadata: nil
                ),
                "SELECT RELEASE_LOCK(?) AS lock_released": MySQLWireQueryResult(
                    rows: [Self.textRow([("lock_released", "1")])],
                    metadata: nil
                ),
                twoRowInsertSQL: MySQLWireQueryResult(rows: [], metadata: nil),
                oneRowInsertSQL: MySQLWireQueryResult(rows: [], metadata: nil)
            ]
        )
        let client = MySQLClient(
            configuration: MySQLConfiguration(host: "localhost", username: "root", database: "sakila"),
            serverConnection: MySQLServerConnection(
                configuration: MySQLConfiguration(host: "localhost", username: "root", database: "sakila"),
                connectionFactory: { _, _ in primary }
            )
        )

        let currentUser = try await client.session.currentUser()
        let currentDatabase = try await client.session.currentDatabase()
        let sqlMode = try await client.session.sqlMode()
        let filteredVariables = try await client.session.sessionVariables(named: ["sql_mode"])
        let isolationLevel = try await client.session.transactionIsolationLevel()
        let acquiredLock = try await client.session.acquireNamedLock("echo-refresh", timeoutSeconds: 5)
        let releasedLock = try await client.session.releaseNamedLock("echo-refresh")
        let updatedSQLMode = try await client.session.setSQLMode("ANSI,STRICT_TRANS_TABLES")
        let updatedOptimizer = try await client.session.setSessionVariable(name: "optimizer_switch", value: nil)
        try await client.session.setTransactionIsolationLevel(.serializable)

        let bulkInsert = try await client.bulk.insert(
            into: "actor",
            schema: "sakila",
            columns: ["actor_id", "first_name"],
            rows: [
                [MySQLData(int: 1), MySQLData(string: "PENELOPE")],
                [MySQLData(int: 2), MySQLData(string: "NICK")],
                [MySQLData(int: 3), MySQLData(string: "ED")]
            ],
            chunkSize: 2
        )
        let loadCommand = client.bulk.loadDataCommand(
            host: "db.internal",
            port: 3306,
            username: "echo",
            database: "sakila",
            table: "actor",
            inputPath: "/tmp/actor.csv",
            ignoreLines: 1
        )
        let exportCommand = client.bulk.exportTableCommand(
            host: "db.internal",
            port: 3306,
            username: "echo",
            database: "sakila",
            table: "actor",
            outputPath: "/tmp/actor.sql",
            whereClause: "actor_id > 10"
        )

        #expect(currentUser == "root@localhost")
        #expect(currentDatabase == "sakila")
        #expect(sqlMode == "STRICT_TRANS_TABLES")
        #expect(filteredVariables == [MySQLSessionVariable(name: "sql_mode", value: "STRICT_TRANS_TABLES")])
        #expect(isolationLevel == .readCommitted)
        #expect(acquiredLock.acquired)
        #expect(releasedLock.acquired)
        #expect(updatedSQLMode == MySQLSessionVariable(name: "sql_mode", value: "ANSI,STRICT_TRANS_TABLES"))
        #expect(updatedOptimizer == MySQLSessionVariable(name: "optimizer_switch", value: "DEFAULT"))
        #expect(bulkInsert == MySQLBulkInsertResult(insertedRowCount: 3, chunksExecuted: 2))
        #expect(loadCommand == [
            "mysql",
            "--host=db.internal",
            "--port=3306",
            "--user=echo",
            "--database=sakila",
            "--local-infile=1",
            "--execute=LOAD DATA LOCAL INFILE '/tmp/actor.csv' INTO TABLE `actor` FIELDS TERMINATED BY ',' LINES TERMINATED BY '\n' IGNORE 1 LINES"
        ])
        #expect(exportCommand == [
            "mysqldump",
            "--host=db.internal",
            "--port=3306",
            "--user=echo",
            "--where=actor_id > 10",
            "--result-file=/tmp/actor.sql",
            "sakila",
            "actor"
        ])
        #expect(await primary.simpleQueries == [
            "SELECT CURRENT_USER() AS account",
            "SHOW SESSION VARIABLES",
            "SHOW SESSION VARIABLES",
            "SHOW SESSION VARIABLES WHERE Variable_name IN ('transaction_isolation', 'tx_isolation')",
            "SET SESSION `optimizer_switch` = DEFAULT",
            "SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE"
        ])
        let preparedQueries = await primary.preparedQueries
        #expect(preparedQueries.map(\.sql) == [
            "SELECT GET_LOCK(?, ?) AS lock_acquired",
            "SELECT RELEASE_LOCK(?) AS lock_released",
            "SET SESSION `sql_mode` = ?",
            twoRowInsertSQL,
            oneRowInsertSQL
        ])
        #expect(preparedQueries.map(\.binds) == [
            ["echo-refresh", "5"],
            ["echo-refresh"],
            ["ANSI,STRICT_TRANS_TABLES"],
            ["1", "PENELOPE", "2", "NICK"],
            ["3", "ED"]
        ])
    }

    @Test
    func securityAdministrationAndBackupOptionsAreTyped() async throws {
        let accountLimitSQL = """
        SELECT
            max_questions,
            max_updates,
            max_connections,
            max_user_connections
        FROM mysql.user
        WHERE User = ? AND Host = ?
        LIMIT 1;
        """

        let metadata = MockConnectionSession(
            simpleQueryResults: [
                "SHOW GRANTS FOR 'ops'@'%'": [
                    Self.textRow([("Grants for ops@%", "GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'ops'@'%'")])
                ]
            ],
            preparedQueryResults: [
                accountLimitSQL: MySQLWireQueryResult(
                    rows: [
                        Self.textRow([
                            ("max_questions", "100"),
                            ("max_updates", "50"),
                            ("max_connections", "25"),
                            ("max_user_connections", "10")
                        ])
                    ],
                    metadata: nil
                )
            ]
        )
        let primary = MockConnectionSession()
        let counter = ConnectionFactoryCounter()
        let client = MySQLClient(
            configuration: MySQLConfiguration(host: "localhost", username: "root", database: "sakila"),
            serverConnection: MySQLServerConnection(
                configuration: MySQLConfiguration(host: "localhost", username: "root", database: "sakila"),
                connectionFactory: { _, _ in
                    let index = await counter.next()
                    return index == 1 ? metadata : primary
                }
            )
        )

        let limits = try await client.security.accountLimits(for: "ops", host: "%")
        let detectedRoles = try await client.security.administrativeRoles(for: "ops", host: "%")
        let updatedLimits = try await client.security.setAccountLimits(
            for: "ops",
            host: "%",
            limits: MySQLAccountLimits(
                maxQueriesPerHour: 200,
                maxUpdatesPerHour: 100,
                maxConnectionsPerHour: 50,
                maxUserConnections: 20
            )
        )
        try await client.security.grantAdministrativeRole(MySQLAdministrativeRole.monitorAdmin, to: "ops", host: "%")
        try await client.security.revokeAdministrativeRole(MySQLAdministrativeRole.monitorAdmin, from: "ops", host: "%")
        let backupCommand = client.backupRestore.backupCommand(
            host: "db.internal",
            port: 3306,
            username: "echo",
            database: "sakila",
            outputPath: "/tmp/sakila.sql",
            options: MySQLDumpOptions(
                includeRoutines: true,
                includeTriggers: false,
                includeEvents: true,
                includeData: false,
                includeSchema: false,
                singleTransaction: true,
                lockTables: true,
                compressConnection: true,
                useExtendedInsert: false,
                whereClause: "actor_id > 100",
                tables: ["actor", "film"]
            )
        )
        let restoreCommand = client.backupRestore.restoreCommand(
            host: "db.internal",
            port: 3306,
            username: "echo",
            database: "sakila",
            inputPath: "/tmp/sakila.sql",
            defaultCharacterSet: "utf8mb4",
            force: true
        )

        #expect(limits == MySQLAccountLimits(
            maxQueriesPerHour: 100,
            maxUpdatesPerHour: 50,
            maxConnectionsPerHour: 25,
            maxUserConnections: 10
        ))
        #expect(detectedRoles.contains(MySQLAdministrativeRole.monitorAdmin))
        #expect(detectedRoles.contains(MySQLAdministrativeRole.processAdmin))
        #expect(updatedLimits.operation == "ALTER USER LIMITS")
        #expect(backupCommand == [
            "mysqldump",
            "--host=db.internal",
            "--port=3306",
            "--user=echo",
            "--result-file=/tmp/sakila.sql",
            "--single-transaction",
            "--lock-tables",
            "--compress",
            "--routines",
            "--events",
            "--no-data",
            "--no-create-info",
            "--skip-extended-insert",
            "--where=actor_id > 100",
            "sakila",
            "actor",
            "film"
        ])
        #expect(restoreCommand == [
            "mysql",
            "--host=db.internal",
            "--port=3306",
            "--user=echo",
            "--default-character-set=utf8mb4",
            "--force",
            "sakila",
            "<",
            "/tmp/sakila.sql"
        ])
        #expect(await primary.simpleQueries == [
            "ALTER USER 'ops'@'%' WITH MAX_QUERIES_PER_HOUR 200 MAX_UPDATES_PER_HOUR 100 MAX_CONNECTIONS_PER_HOUR 50 MAX_USER_CONNECTIONS 20",
            "GRANT PROCESS, REPLICATION CLIENT ON *.* TO 'ops'@'%'",
            "REVOKE PROCESS, REPLICATION CLIENT ON *.* FROM 'ops'@'%'"
        ])
    }

    @Test
    func programmableObjectDDLUsesExpectedStatements() async throws {
        let primary = MockConnectionSession()
        let client = MySQLClient(
            configuration: MySQLConfiguration(host: "localhost", username: "root", database: "sakila"),
            serverConnection: MySQLServerConnection(
                configuration: MySQLConfiguration(host: "localhost", username: "root", database: "sakila"),
                connectionFactory: { _, _ in primary }
            )
        )

        try await client.views.createView(
            schema: "sakila",
            name: "actor_names",
            definitionSQL: "SELECT actor_id, first_name FROM actor",
            replace: true
        )
        try await client.views.alterView(
            schema: "sakila",
            name: "actor_names",
            definitionSQL: "SELECT actor_id, last_name FROM actor"
        )
        try await client.views.dropView(schema: "sakila", name: "actor_names")
        try await client.routines.createRoutine(
            schema: "sakila",
            name: "film_count",
            kind: .function,
            returnsSQL: "INT",
            characteristicsSQL: "DETERMINISTIC",
            bodySQL: "RETURN 42"
        )
        try await client.routines.dropRoutine(schema: "sakila", name: "film_count", kind: .function)
        try await client.triggers.createTrigger(
            schema: "sakila",
            name: "actor_bi",
            timing: .before,
            event: .insert,
            table: "actor",
            bodySQL: "SET NEW.first_name = UPPER(NEW.first_name);"
        )
        try await client.triggers.dropTrigger(schema: "sakila", name: "actor_bi")
        try await client.events.createEvent(
            schema: "sakila",
            name: "daily_cleanup",
            scheduleSQL: "EVERY 1 DAY",
            bodySQL: "DELETE FROM audit_log WHERE created_at < NOW() - INTERVAL 30 DAY"
        )
        try await client.events.alterEvent(
            schema: "sakila",
            name: "daily_cleanup",
            scheduleSQL: "EVERY 7 DAY",
            bodySQL: "DELETE FROM audit_log WHERE created_at < NOW() - INTERVAL 90 DAY",
            enabled: false
        )
        try await client.events.dropEvent(schema: "sakila", name: "daily_cleanup")

        #expect(await primary.simpleQueries == [
            "CREATE OR REPLACE VIEW `sakila`.`actor_names` AS SELECT actor_id, first_name FROM actor",
            "ALTER VIEW `sakila`.`actor_names` AS SELECT actor_id, last_name FROM actor",
            "DROP VIEW IF EXISTS `sakila`.`actor_names`",
            "CREATE FUNCTION `sakila`.`film_count`() RETURNS INT DETERMINISTIC RETURN 42",
            "DROP FUNCTION IF EXISTS `sakila`.`film_count`",
            "CREATE TRIGGER `sakila`.`actor_bi` BEFORE INSERT ON `sakila`.`actor` FOR EACH ROW SET NEW.first_name = UPPER(NEW.first_name);",
            "DROP TRIGGER IF EXISTS `sakila`.`actor_bi`",
            "CREATE EVENT `sakila`.`daily_cleanup` ON SCHEDULE EVERY 1 DAY ON COMPLETION PRESERVE ENABLE DO DELETE FROM audit_log WHERE created_at < NOW() - INTERVAL 30 DAY",
            "ALTER EVENT `sakila`.`daily_cleanup` ON SCHEDULE EVERY 7 DAY DISABLE DO DELETE FROM audit_log WHERE created_at < NOW() - INTERVAL 90 DAY",
            "DROP EVENT IF EXISTS `sakila`.`daily_cleanup`"
        ])
    }

    @Test
    func performanceReportHelpersUseExpectedStatements() async throws {
        let activity = MockConnectionSession(
            simpleQueryResults: [
                "SELECT * FROM sys.memory_global_by_current_bytes\nLIMIT 50": [
                    Self.textRow([
                        ("event_name", "memory/sql/THD::main_mem_root"),
                        ("current_alloc", "1024")
                    ])
                ],
                "SELECT * FROM sys.io_global_by_file_by_bytes\nLIMIT 50": [
                    Self.textRow([
                        ("file", "ibdata1"),
                        ("total", "4096")
                    ])
                ]
            ]
        )

        let client = MySQLClient(
            configuration: MySQLConfiguration(host: "localhost", username: "root", database: "sakila"),
            serverConnection: MySQLServerConnection(
                configuration: MySQLConfiguration(host: "localhost", username: "root", database: "sakila"),
                connectionFactory: { _, _ in activity }
            )
        )

        let memory = try await client.performance.memoryGlobalByCurrentBytes()
        let io = try await client.performance.ioGlobalByFileByBytes()

        #expect(memory.name == "memory_global_by_current_bytes")
        #expect((memory.rows.first?["event_name"] ?? "") == "memory/sql/THD::main_mem_root")
        #expect(io.name == "io_global_by_file_by_bytes")
        #expect((io.rows.first?["file"] ?? "") == "ibdata1")
        #expect(await activity.simpleQueries == [
            "SELECT * FROM sys.memory_global_by_current_bytes\nLIMIT 50",
            "SELECT * FROM sys.io_global_by_file_by_bytes\nLIMIT 50"
        ])
    }

    private static func textRow(_ values: [(String, String?)]) -> MySQLRow {
        MySQLRow(textColumns: values.map { (name: $0.0, value: $0.1) })
    }
}

@Suite("MySQL type names and placeholders")
struct MySQLTypeNameAndPlaceholderTests {
    @Test func sqlTypeNames() {
        #expect(MySQLColumn(name: "a", type: .longlong, flags: .unsigned).sqlTypeName == "BIGINT UNSIGNED")
        #expect(MySQLColumn(name: "a", type: .long).sqlTypeName == "INT")
        #expect(MySQLColumn(name: "a", type: .newdecimal, decimals: 30, length: 67).sqlTypeName == "DECIMAL(65,30)")
        #expect(MySQLColumn(name: "a", type: .newdecimal, decimals: 2, length: 12).sqlTypeName == "DECIMAL(10,2)")
        #expect(MySQLColumn(name: "a", type: .varString).sqlTypeName == "VARCHAR")
        #expect(MySQLColumn(name: "a", type: .varString, characterSet: 63).sqlTypeName == "VARBINARY")
        #expect(MySQLColumn(name: "a", type: .string, flags: .enum).sqlTypeName == "ENUM")
        #expect(MySQLColumn(name: "a", type: .blob).sqlTypeName == "TEXT")
        #expect(MySQLColumn(name: "a", type: .blob, characterSet: 63).sqlTypeName == "BLOB")
        #expect(MySQLColumn(name: "a", type: .bit, length: 1).sqlTypeName == "BIT")
        #expect(MySQLColumn(name: "a", type: .bit, length: 64).sqlTypeName == "BIT(64)")
        #expect(MySQLColumn(name: "a", type: .datetime).sqlTypeName == "DATETIME")
        #expect(MySQLColumn(name: "a", type: .json).sqlTypeName == "JSON")
    }

    @Test func placeholdersOutsideLiteralsAndComments() throws {
        let sql = "SELECT ?, '?', \"?\", `?`, 'it''s ?' -- ?\n, ? /* ? */ # ?\n, ?"
        #expect(MySQLPlaceholders.positions(in: sql).count == 3)
        #expect(try MySQLPlaceholders.render("SELECT ?, ?", literals: ["1", "'a'"]) == "SELECT 1, 'a'")
        #expect(throws: MySQLWireError.self) { _ = try MySQLPlaceholders.render("SELECT ?", literals: []) }
        #expect(MySQLPlaceholders.positions(in: "SELECT 'a\\'?' , ?").count == 1)
    }
}
