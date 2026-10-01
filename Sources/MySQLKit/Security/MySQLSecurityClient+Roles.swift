import MySQLWire

public extension MySQLSecurityClient {
    /// Every role that is granted to an account or another role. MySQL keeps the grants in
    /// `mysql.role_edges`; MariaDB in `mysql.roles_mapping`, where roles have no host (`""` here).
    func listRoles() async throws -> [MySQLRoleDefinition] {
        let mariaDB = try await isMariaDB()
        let sql = mariaDB
            ? "SELECT DISTINCT Role AS role_name, '' AS role_host FROM mysql.roles_mapping ORDER BY Role"
            : "SELECT DISTINCT FROM_USER AS role_name, FROM_HOST AS role_host FROM mysql.role_edges ORDER BY FROM_USER, FROM_HOST"
        let connection = try await serverConnection.metadata()
        return try await connection.simpleQuery(sql).compactMap { row in
            guard let name = row.field("role_name")?.string, let host = row.field("role_host")?.string else { return nil }
            return MySQLRoleDefinition(name: name, host: host)
        }
    }

    /// Who has which role. The grantee is written `'user'@'host'`.
    func listRoleAssignments() async throws -> [MySQLRoleAssignment] {
        let mariaDB = try await isMariaDB()
        // MariaDB lists a role's creator as holding it (with Admin_option); those are kept, like MySQL's
        // edges they are real grants.
        let sql = mariaDB
            ? "SELECT Role AS role_name, '' AS role_host, User AS to_user, Host AS to_host FROM mysql.roles_mapping ORDER BY User, Role"
            : "SELECT FROM_USER AS role_name, FROM_HOST AS role_host, TO_USER AS to_user, TO_HOST AS to_host FROM mysql.role_edges ORDER BY TO_USER, FROM_USER"
        let connection = try await serverConnection.metadata()
        return try await connection.simpleQuery(sql).compactMap { row in
            guard
                let roleName = row.field("role_name")?.string,
                let roleHost = row.field("role_host")?.string,
                let toUser = row.field("to_user")?.string,
                let toHost = row.field("to_host")?.string
            else { return nil }
            return MySQLRoleAssignment(roleName: roleName, roleHost: roleHost, grantee: "'\(toUser)'@'\(toHost)'")
        }
    }
}
