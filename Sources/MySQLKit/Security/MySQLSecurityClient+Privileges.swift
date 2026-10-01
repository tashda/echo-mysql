import MySQLWire

public extension MySQLSecurityClient {
    func schemaPrivileges(for grantee: String? = nil) async throws -> [MySQLPrivilegeGrant] {
        let sql: String
        let binds: [MySQLData]

        if let grantee, !grantee.isEmpty {
            sql = """
            SELECT
                grantee,
                table_schema,
                privilege_type,
                is_grantable
            FROM information_schema.schema_privileges
            WHERE grantee = ?
            ORDER BY grantee, table_schema, privilege_type;
            """
            binds = [MySQLData(string: grantee)]
        } else {
            sql = """
            SELECT
                grantee,
                table_schema,
                privilege_type,
                is_grantable
            FROM information_schema.schema_privileges
            ORDER BY grantee, table_schema, privilege_type;
            """
            binds = []
        }

        let connection = try await serverConnection.metadata()
        let result = try await connection.query(sql, binds: binds)
        return result.rows.compactMap { row in
            guard
                let grantee = row.field("grantee")?.string,
                let tableSchema = row.field("table_schema")?.string,
                let privilegeType = row.field("privilege_type")?.string
            else {
                return nil
            }

            return MySQLPrivilegeGrant(
                grantee: grantee,
                tableSchema: tableSchema,
                tableName: nil,
                privilegeType: privilegeType,
                isGrantable: row.field("is_grantable")?.string?.uppercased() == "YES"
            )
        }
    }

    func tablePrivileges(for grantee: String? = nil) async throws -> [MySQLPrivilegeGrant] {
        let sql: String
        let binds: [MySQLData]

        if let grantee, !grantee.isEmpty {
            sql = """
            SELECT
                grantee,
                table_schema,
                table_name,
                privilege_type,
                is_grantable
            FROM information_schema.table_privileges
            WHERE grantee = ?
            ORDER BY table_schema, table_name, privilege_type;
            """
            binds = [MySQLData(string: grantee)]
        } else {
            sql = """
            SELECT
                grantee,
                table_schema,
                table_name,
                privilege_type,
                is_grantable
            FROM information_schema.table_privileges
            ORDER BY grantee, table_schema, table_name, privilege_type;
            """
            binds = []
        }

        let connection = try await serverConnection.metadata()
        let result = try await connection.query(sql, binds: binds)
        return result.rows.compactMap { row in
            guard
                let grantee = row.field("grantee")?.string,
                let privilegeType = row.field("privilege_type")?.string
            else { return nil }

            return MySQLPrivilegeGrant(
                grantee: grantee,
                tableSchema: row.field("table_schema")?.string,
                tableName: row.field("table_name")?.string,
                privilegeType: privilegeType,
                isGrantable: row.field("is_grantable")?.string?.uppercased() == "YES"
            )
        }
    }
}
