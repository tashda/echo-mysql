import MySQLWire

public extension MySQLSecurityClient {
    func listRoles() async throws -> [MySQLRoleDefinition] {
        let sql = """
        SELECT
            FROM_USER,
            FROM_HOST
        FROM mysql.role_edges
        GROUP BY FROM_USER, FROM_HOST
        ORDER BY FROM_USER, FROM_HOST;
        """

        let connection = try await serverConnection.metadata()
        let result = try await connection.query(sql, binds: [])
        return result.rows.compactMap { row in
            guard
                let roleName = row.field("FROM_USER")?.string,
                let roleHost = row.field("FROM_HOST")?.string
            else { return nil }

            return MySQLRoleDefinition(name: roleName, host: roleHost)
        }
    }

    func listRoleAssignments() async throws -> [MySQLRoleAssignment] {
        let sql = """
        SELECT
            FROM_USER,
            FROM_HOST,
            TO_USER,
            TO_HOST
        FROM mysql.role_edges
        ORDER BY TO_USER, FROM_USER;
        """

        let connection = try await serverConnection.metadata()
        let result = try await connection.query(sql, binds: [])
        return result.rows.compactMap { row in
            guard
                let roleName = row.field("FROM_USER")?.string,
                let roleHost = row.field("FROM_HOST")?.string,
                let toUser = row.field("TO_USER")?.string,
                let toHost = row.field("TO_HOST")?.string
            else { return nil }

            return MySQLRoleAssignment(
                roleName: roleName,
                roleHost: roleHost,
                grantee: "'\(toUser)'@'\(toHost)'"
            )
        }
    }
}
