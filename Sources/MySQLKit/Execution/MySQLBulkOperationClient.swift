
public struct MySQLBulkOperationClient: Sendable {
    let serverConnection: MySQLServerConnection

    public func insert(
        into table: String,
        schema: String? = nil,
        columns: [String],
        rows: [[MySQLData]],
        chunkSize: Int = 500
    ) async throws -> MySQLBulkInsertResult {
        guard !rows.isEmpty else {
            return MySQLBulkInsertResult(insertedRowCount: 0, chunksExecuted: 0)
        }

        let boundedChunkSize = max(1, chunkSize)
        let connection = try await serverConnection.primary()

        var insertedRowCount = 0
        var chunksExecuted = 0

        for batch in rows.chunked(into: boundedChunkSize) {
            let sql = makeInsertSQL(
                table: table,
                schema: schema,
                columns: columns,
                rowWidth: columns.count,
                rowCount: batch.count
            )
            let binds = batch.flatMap { $0 }
            _ = try await connection.query(sql, binds: binds)
            insertedRowCount += batch.count
            chunksExecuted += 1
        }

        return MySQLBulkInsertResult(insertedRowCount: insertedRowCount, chunksExecuted: chunksExecuted)
    }

    public func loadDataCommand(
        host: String,
        port: Int,
        username: String,
        database: String,
        table: String,
        inputPath: String,
        fieldTerminator: String = ",",
        lineTerminator: String = "\n",
        ignoreLines: Int = 0
    ) -> [String] {
        [
            "mysql",
            "--host=\(host)",
            "--port=\(port)",
            "--user=\(username)",
            "--database=\(database)",
            "--local-infile=1",
            "--execute=LOAD DATA LOCAL INFILE '\(MySQLBindRenderer.escapeStringLiteral(inputPath))' INTO TABLE `\(escapedIdentifier(table))` FIELDS TERMINATED BY '\(MySQLBindRenderer.escapeStringLiteral(fieldTerminator))' LINES TERMINATED BY '\(MySQLBindRenderer.escapeStringLiteral(lineTerminator))' IGNORE \(ignoreLines) LINES"
        ]
    }

    public func exportTableCommand(
        host: String,
        port: Int,
        username: String,
        database: String,
        table: String,
        outputPath: String,
        whereClause: String? = nil
    ) -> [String] {
        var command = [
            "mysqldump",
            "--host=\(host)",
            "--port=\(port)",
            "--user=\(username)",
            "--result-file=\(outputPath)",
            database,
            table
        ]

        if let whereClause, !whereClause.isEmpty {
            command.insert("--where=\(whereClause)", at: 4)
        }

        return command
    }

    private func makeInsertSQL(
        table: String,
        schema: String?,
        columns: [String],
        rowWidth: Int,
        rowCount: Int
    ) -> String {
        let qualifiedTable: String
        if let schema, !schema.isEmpty {
            qualifiedTable = "`\(escapedIdentifier(schema))`.`\(escapedIdentifier(table))`"
        } else {
            qualifiedTable = "`\(escapedIdentifier(table))`"
        }

        let columnList = columns.map { "`\(escapedIdentifier($0))`" }.joined(separator: ", ")
        let placeholders = Array(
            repeating: "(" + Array(repeating: "?", count: rowWidth).joined(separator: ", ") + ")",
            count: rowCount
        )
        .joined(separator: ", ")
        return "INSERT INTO \(qualifiedTable) (\(columnList)) VALUES \(placeholders)"
    }

    private func escapedIdentifier(_ value: String) -> String {
        value.replacingOccurrences(of: "`", with: "``")
    }
}

public struct MySQLBulkInsertResult: Sendable, Hashable {
    public let insertedRowCount: Int
    public let chunksExecuted: Int

    public init(insertedRowCount: Int, chunksExecuted: Int) {
        self.insertedRowCount = insertedRowCount
        self.chunksExecuted = chunksExecuted
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }

        var chunks: [[Element]] = []
        chunks.reserveCapacity((count + size - 1) / size)

        var index = startIndex
        while index < endIndex {
            let nextIndex = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(Array(self[index..<nextIndex]))
            index = nextIndex
        }

        return chunks
    }
}
