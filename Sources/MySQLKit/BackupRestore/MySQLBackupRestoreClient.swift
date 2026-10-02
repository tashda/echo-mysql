public struct MySQLBackupRestoreClient: Sendable {
    let serverConnection: MySQLServerConnection

    public func backupCommand(
        host: String,
        port: Int,
        username: String,
        database: String,
        outputPath: String
    ) -> [String] {
        backupCommand(
            host: host,
            port: port,
            username: username,
            database: database,
            outputPath: outputPath,
            options: MySQLDumpOptions()
        )
    }

    public func backupCommand(
        host: String,
        port: Int,
        username: String,
        database: String,
        outputPath: String,
        options: MySQLDumpOptions,
        tlsArguments: [String] = []
    ) -> [String] {
        var command = [
            "mysqldump",
            "--host=\(host)",
            "--port=\(port)",
            "--user=\(username)",
        ] + tlsArguments + [
            "--result-file=\(outputPath)",
        ]

        if options.singleTransaction {
            command.append("--single-transaction")
        }
        if options.lockTables {
            command.append("--lock-tables")
        }
        if options.compressConnection {
            command.append("--compress")
        }
        if options.includeRoutines {
            command.append("--routines")
        }
        if options.includeTriggers {
            command.append("--triggers")
        }
        if options.includeEvents {
            command.append("--events")
        }
        if !options.includeData {
            command.append("--no-data")
        }
        if !options.includeSchema {
            command.append("--no-create-info")
        }
        if !options.useExtendedInsert {
            command.append("--skip-extended-insert")
        }
        if let whereClause = options.whereClause, !whereClause.isEmpty {
            command.append("--where=\(whereClause)")
        }

        command.append(database)
        if !options.tables.isEmpty {
            command.append(contentsOf: options.tables)
        }

        return command
    }

    public func restoreCommand(
        host: String,
        port: Int,
        username: String,
        database: String,
        inputPath: String,
        defaultCharacterSet: String? = nil,
        force: Bool = false,
        tlsArguments: [String] = []
    ) -> [String] {
        var command = [
            "mysql",
            "--host=\(host)",
            "--port=\(port)",
            "--user=\(username)",
        ] + tlsArguments

        if let defaultCharacterSet, !defaultCharacterSet.isEmpty {
            command.append("--default-character-set=\(defaultCharacterSet)")
        }
        if force {
            command.append("--force")
        }

        command.append(contentsOf: [
            database,
            "<",
            inputPath
        ]
        )

        return command
    }
}
