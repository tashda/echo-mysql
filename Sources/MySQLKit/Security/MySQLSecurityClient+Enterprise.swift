import MySQLWire

public extension MySQLSecurityClient {

    // MARK: - Password Policies

    /// Loads password-policy-related global variables from performance_schema.
    func passwordPolicyVariables() async throws -> [MySQLGlobalVariable] {
        let names = [
            "default_password_lifetime",
            "password_history",
            "password_reuse_interval",
            "password_require_current",
            "validate_password.policy",
            "validate_password.length",
            "validate_password.mixed_case_count",
            "validate_password.number_count",
            "validate_password.special_char_count",
            "validate_password_policy",
            "validate_password_length",
            "validate_password_mixed_case_count",
            "validate_password_number_count",
            "validate_password_special_char_count",
            "disconnect_on_expired_password",
            "authentication_policy"
        ]

        let placeholders = names.map { _ in "?" }.joined(separator: ", ")
        let sql = """
        SELECT Variable_name, Value FROM performance_schema.global_variables
        WHERE Variable_name IN (\(placeholders))
        ORDER BY Variable_name
        """

        let connection = try await serverConnection.activity()
        let result = try await connection.query(sql, binds: names.map { MySQLData(string: $0) })
        return result.rows.compactMap { row in
            guard
                let name = row.field("Variable_name")?.string,
                let value = row.field("Value")?.string
            else { return nil }
            return MySQLGlobalVariable(name: name, value: value)
        }
    }

    // MARK: - Data Masking

    /// Returns `true` if the MySQL data masking component is installed.
    func maskingComponentInstalled() async throws -> Bool {
        let sql = """
        SELECT COUNT(*) AS cnt FROM information_schema.COMPONENTS
        WHERE COMPONENT_URN LIKE '%data_masking%'
        """
        let connection = try await serverConnection.activity()
        let result = try await connection.query(sql, binds: [])
        let count = result.rows.first?.field("cnt")?.string.flatMap(Int.init) ?? 0
        return count > 0
    }

    /// Lists columns that have masking-related generation expressions.
    func maskingRules(limit: Int = 100) async throws -> [MySQLMaskingRule] {
        let sql = """
        SELECT TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME, 'MASK' AS mask_function
        FROM information_schema.COLUMNS
        WHERE GENERATION_EXPRESSION LIKE '%mask%'
        ORDER BY TABLE_SCHEMA, TABLE_NAME, COLUMN_NAME
        LIMIT ?
        """
        let connection = try await serverConnection.activity()
        let result = try await connection.query(sql, binds: [MySQLData(int: limit)])
        return result.rows.compactMap { row in
            guard
                let schema = row.field("TABLE_SCHEMA")?.string,
                let table = row.field("TABLE_NAME")?.string,
                let column = row.field("COLUMN_NAME")?.string
            else { return nil }
            return MySQLMaskingRule(
                schema: schema,
                table: table,
                column: column,
                function: row.field("mask_function")?.string ?? "MASK"
            )
        }
    }

    // MARK: - Encryption

    /// Loads encryption-related global variables from performance_schema.
    func encryptionVariables() async throws -> [MySQLGlobalVariable] {
        let names = [
            "innodb_encrypt_tables",
            "innodb_encrypt_log",
            "innodb_redo_log_encrypt",
            "innodb_undo_log_encrypt",
            "table_encryption_privilege_check",
            "default_table_encryption",
            "keyring_file_data",
            "early-plugin-load",
            "binlog_encryption",
            "encrypt_tmp_files",
            "have_ssl",
            "have_openssl",
            "ssl_ca",
            "ssl_cert",
            "ssl_key",
            "tls_version",
            "tls_ciphersuites"
        ]

        let placeholders = names.map { _ in "?" }.joined(separator: ", ")
        let sql = """
        SELECT Variable_name, Value FROM performance_schema.global_variables
        WHERE Variable_name IN (\(placeholders))
        ORDER BY Variable_name
        """

        let connection = try await serverConnection.activity()
        let result = try await connection.query(sql, binds: names.map { MySQLData(string: $0) })
        return result.rows.compactMap { row in
            guard
                let name = row.field("Variable_name")?.string,
                let value = row.field("Value")?.string
            else { return nil }
            return MySQLGlobalVariable(name: name, value: value)
        }
    }

    /// Lists tables that have ENCRYPTION in their CREATE_OPTIONS.
    func encryptedTables(limit: Int = 50) async throws -> [MySQLEncryptedTable] {
        let sql = """
        SELECT TABLE_SCHEMA, TABLE_NAME, CREATE_OPTIONS
        FROM information_schema.TABLES
        WHERE CREATE_OPTIONS LIKE '%ENCRYPTION%'
        ORDER BY TABLE_SCHEMA, TABLE_NAME
        LIMIT ?
        """
        let connection = try await serverConnection.activity()
        let result = try await connection.query(sql, binds: [MySQLData(int: limit)])
        return result.rows.compactMap { row in
            guard
                let schema = row.field("TABLE_SCHEMA")?.string,
                let table = row.field("TABLE_NAME")?.string
            else { return nil }
            return MySQLEncryptedTable(
                schema: schema,
                table: table,
                createOptions: row.field("CREATE_OPTIONS")?.string
            )
        }
    }

    // MARK: - Audit Log

    /// Returns `true` if the MySQL audit_log plugin is installed.
    func auditPluginInstalled() async throws -> Bool {
        let sql = """
        SELECT PLUGIN_STATUS FROM information_schema.PLUGINS
        WHERE PLUGIN_NAME = 'audit_log'
        """
        let connection = try await serverConnection.activity()
        let result = try await connection.query(sql, binds: [])
        return !result.rows.isEmpty
    }

    /// Reads entries from `mysql.audit_log_filter` (MySQL Enterprise).
    func auditLogFilters(limit: Int = 50) async throws -> [MySQLAuditLogFilter] {
        let sql = "SELECT * FROM mysql.audit_log_filter LIMIT \(limit)"
        let connection = try await serverConnection.activity()
        let rows = try await connection.simpleQuery(sql)
        return rows.enumerated().map { index, row in
            let columns = row.columnDefinitions
            let values = columns.map { row.column($0.name)?.string }
            let filterName = values.first.flatMap({ $0 }) ?? "\(index)"
            let definition = values.dropFirst().first.flatMap({ $0 })
            return MySQLAuditLogFilter(
                filterName: filterName,
                definition: definition
            )
        }
    }

    /// Reads recent entries from `mysql.general_log` as a fallback audit source.
    func generalLogEntries(limit: Int = 50) async throws -> [MySQLGeneralLogEntry] {
        let sql = """
        SELECT event_time, user_host, command_type, argument
        FROM mysql.general_log
        ORDER BY event_time DESC
        LIMIT \(limit)
        """
        let connection = try await serverConnection.activity()
        let rows = try await connection.simpleQuery(sql)
        return rows.compactMap { row in
            MySQLGeneralLogEntry(
                eventTime: row.field("event_time")?.string,
                userHost: row.field("user_host")?.string,
                commandType: row.field("command_type")?.string,
                argument: row.field("argument")?.string
            )
        }
    }

    // MARK: - Firewall

    /// Returns `true` if the MySQL Enterprise Firewall plugin is installed.
    func firewallPluginInstalled() async throws -> Bool {
        let sql = """
        SELECT PLUGIN_STATUS FROM information_schema.PLUGINS
        WHERE PLUGIN_NAME = 'MYSQL_FIREWALL'
        """
        let connection = try await serverConnection.activity()
        let result = try await connection.query(sql, binds: [])
        return !result.rows.isEmpty
    }

    /// Reads firewall whitelist rules (MySQL Enterprise).
    func firewallRules(limit: Int = 100) async throws -> [MySQLFirewallRule] {
        let sql = """
        SELECT USERHOST, RULE, MODE
        FROM mysql.firewall_whitelist
        ORDER BY USERHOST
        LIMIT \(limit)
        """
        let connection = try await serverConnection.activity()
        let rows = try await connection.simpleQuery(sql)
        return rows.compactMap { row in
            guard let userhost = row.field("USERHOST")?.string else { return nil }
            return MySQLFirewallRule(
                userhost: userhost,
                rule: row.field("RULE")?.string ?? "",
                mode: row.field("MODE")?.string ?? ""
            )
        }
    }
}
