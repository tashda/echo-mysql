import Foundation
import MySQLKit
import MySQLKitTesting
import Testing

/// Accounts, roles and privileges, checked by logging in as the accounts the tests create.
@Suite(.testServer)
struct SecurityTests {
    /// Logs in as `username` and returns `CURRENT_USER()`, or the error.
    static func login(_ server: TestServer, _ username: String, _ password: String,
                      database: String? = nil) async -> Result<String, any Error> {
        let client = server.client(server.configuration(username: username, password: .some(password), database: .some(database)))
        defer { Task { await client.close() } }
        do {
            return .success(try await client.session.currentUser() ?? "")
        } catch {
            return .failure(error)
        }
    }

    @Test func createLoginAlterLockAndDropUsers() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            let user = TestServer.uniqueName("user")
            let password = #"Pa55'w\rd"#
            defer { Task { _ = try? await server.withClient { try await $0.security.dropUser(username: user, host: "%") } } }

            let created = try await client.security.createUser(username: user, host: "%", password: password)
            #expect(created.operation == "CREATE USER")
            #expect(try await client.security.listUsers().contains { $0.username == user && $0.host == "%" })
            #expect(try await Self.login(server, user, password).get().hasPrefix(user))

            _ = try await client.security.alterUserPassword(username: user, host: "%", password: "second-Password1")
            await #expect(throws: (any Error).self) { try await Self.login(server, user, password).get() }
            #expect(try await Self.login(server, user, "second-Password1").get().hasPrefix(user))

            _ = try await client.security.lockUser(username: user, host: "%")
            #expect(try await client.security.listUsers().first { $0.username == user }?.accountLocked == true)
            await #expect(throws: (any Error).self) { try await Self.login(server, user, "second-Password1").get() }
            _ = try await client.security.unlockUser(username: user, host: "%")
            #expect(try await client.security.listUsers().first { $0.username == user }?.accountLocked == false)
            #expect(try await Self.login(server, user, "second-Password1").get().hasPrefix(user))

            _ = try await client.security.dropUser(username: user, host: "%")
            _ = try await client.security.dropUser(username: user, host: "%")  // IF EXISTS
            #expect(try await !client.security.listUsers().contains { $0.username == user })
        }
    }

    @Test func grantsGiveAndTakeAccess() async throws {
        let server = try TestServer.require()
        try await server.withSchema { client, schema in
            try await client.admin.createTable(schema: schema, name: "secret", columns: [MySQLColumnDefinition(name: "v", dataType: "INT")])
            let user = TestServer.uniqueName("reader")
            defer { Task { _ = try? await server.withClient { try await $0.security.dropUser(username: user, host: "%") } } }
            _ = try await client.security.createUser(username: user, host: "%", password: "Reader-Password1")

            // Without a grant the schema is invisible.
            let reader = server.client(server.configuration(username: user, password: .some("Reader-Password1")))
            defer { Task { await reader.close() } }
            await #expect(throws: (any Error).self) { _ = try await reader.simpleQuery("SELECT * FROM `\(schema)`.secret") }

            try await client.security.grant("SELECT", on: "`\(schema)`.*", to: user, host: "%")
            _ = try await reader.simpleQuery("SELECT * FROM `\(schema)`.secret")
            let grants = try await client.security.showGrants(for: user, host: "%")
            #expect(grants.contains { $0.contains("GRANT SELECT ON `\(schema)`.*") })
            let privileges = try await client.security.schemaPrivileges(for: "'\(user)'@'%'")
            #expect(privileges.contains { $0.tableSchema == schema && $0.privilegeType == "SELECT" })

            try await client.security.revoke("SELECT", on: "`\(schema)`.*", from: user, host: "%")
            #expect(try await !client.security.showGrants(for: user, host: "%").contains { $0.contains("`\(schema)`") })

            try await client.security.grant("SELECT", on: "`\(schema)`.`secret`", to: user, host: "%", withGrantOption: true)
            let tablePrivileges = try await client.security.tablePrivileges(for: "'\(user)'@'%'")
            #expect(tablePrivileges.contains { $0.tableName == "secret" && $0.isGrantable })
        }
    }

    @Test func rolesAndDefaultRoles() async throws {
        let server = try TestServer.require()
        try await server.withSchema { client, schema in
            try await client.admin.createTable(schema: schema, name: "report", columns: [MySQLColumnDefinition(name: "v", dataType: "INT")])
            let role = TestServer.uniqueName("role")
            let user = TestServer.uniqueName("analyst")
            defer {
                Task {
                    _ = try? await server.withClient { admin in
                        _ = try? await admin.security.dropUser(username: user, host: "%")
                        try? await admin.security.dropRole(name: role)
                    }
                }
            }
            try await client.security.createRole(name: role)
            try await client.security.grant("SELECT", on: "`\(schema)`.*", to: role, host: nil)
            _ = try await client.security.createUser(username: user, host: "%", password: "Analyst-Password1")
            try await client.security.grantRole(role, to: user, host: "%")
            try await client.security.setDefaultRole(role, for: user, host: "%")

            #expect(try await client.security.listRoles().contains { $0.name == role })
            #expect(try await client.security.listRoleAssignments().contains { $0.roleName == role && $0.grantee.contains(user) })

            // The default role is active at login, so the role's grant works.
            let analyst = server.client(server.configuration(username: user, password: .some("Analyst-Password1")))
            defer { Task { await analyst.close() } }
            _ = try await analyst.simpleQuery("SELECT * FROM `\(schema)`.report")

            try await client.security.revokeRole(role, from: user, host: "%")
            #expect(try await !client.security.listRoleAssignments().contains { $0.roleName == role && $0.grantee.contains(user) })
            try await client.security.dropRole(name: role)
        }
    }

    @Test func accountLimitsAndAdministrativeRoles() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            let user = TestServer.uniqueName("limited")
            defer { Task { _ = try? await server.withClient { try await $0.security.dropUser(username: user, host: "%") } } }
            _ = try await client.security.createUser(username: user, host: "%", password: "Limited-Password1")
            let limits = MySQLAccountLimits(maxQueriesPerHour: 100, maxUpdatesPerHour: 10, maxConnectionsPerHour: 5, maxUserConnections: 2)
            _ = try await client.security.setAccountLimits(for: user, host: "%", limits: limits)
            #expect(try await client.security.accountLimits(for: user, host: "%") == limits)

            try await client.security.grantAdministrativeRole(.processAdmin, to: user, host: "%")
            #expect(try await client.security.administrativeRoles(for: user, host: "%").contains(.processAdmin))
            try await client.security.revokeAdministrativeRole(.processAdmin, from: user, host: "%")
            #expect(try await !client.security.administrativeRoles(for: user, host: "%").contains(.processAdmin))
        }
    }

    @Test func tlsRequirementIsEnforced() async throws {
        let server = try TestServer.require()
        let flavor = try await server.flavor()
        try await server.withClient { client in
            let user = TestServer.uniqueName("tls")
            defer { Task { _ = try? await server.withClient { try await $0.security.dropUser(username: user, host: "%") } } }
            _ = try await client.security.createUser(username: user, host: "%", password: "Tls-Password1", tls: .ssl)
            let createUser = try await client.simpleQuery("SHOW CREATE USER '\(user)'@'%'")
            let statement = createUser.first.flatMap { row in row.columnDefinitions.first.flatMap { row.column($0.name)?.string } } ?? ""
            #expect(statement.contains("REQUIRE SSL"))

            let encrypted = server.client(server.configuration(username: user, password: .some("Tls-Password1"), tlsMode: .preferred))
            defer { Task { await encrypted.close() } }
            if try await ConnectionTests.serverOffersTLS(server) {
                _ = try await encrypted.simpleQuery("SELECT 1")
            }
            // Without TLS the server refuses the account (MySQL refuses caching_sha2 without TLS anyway).
            if flavor.isMariaDB {
                let plain = server.client(server.configuration(username: user, password: .some("Tls-Password1"), tlsMode: .disabled))
                defer { Task { await plain.close() } }
                await #expect(throws: (any Error).self) { _ = try await plain.simpleQuery("SELECT 1") }
            }

            _ = try await client.security.alterUserTLS(username: user, host: "%", tls: .subject("/CN=\(user)"))
            let altered = try await client.simpleQuery("SHOW CREATE USER '\(user)'@'%'")
            let alteredStatement = altered.first.flatMap { row in row.columnDefinitions.first.flatMap { row.column($0.name)?.string } } ?? ""
            #expect(alteredStatement.contains("REQUIRE SUBJECT"))
            _ = try await client.security.alterUserTLS(username: user, host: "%", tls: .none)
        }
    }

    /// Backslashes in names and passwords reach the server intact, whether or not the session's
    /// sql_mode treats a backslash as an escape character.
    @Test(arguments: ["", "NO_BACKSLASH_ESCAPES"])
    func backslashesInNamesAndPasswords(sqlMode: String) async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            if !sqlMode.isEmpty { _ = try await client.session.setSQLMode(sqlMode) }
            let user = TestServer.uniqueName("b") + #"\x"#  // uniqueName keeps only letters and digits
            let password = #"p\a'ss\"#
            defer { Task { _ = try? await server.withClient { try await $0.security.dropUser(username: user, host: "%") } } }
            _ = try await client.security.createUser(username: user, host: "%", password: password)
            let stored = try await client.query("SELECT User FROM mysql.user WHERE User = ?", binds: [MySQLData(string: user)])
            #expect(stored.rows.count == 1)
            #expect(try await Self.login(server, user, password).get().hasPrefix(user))
        }
    }

    @Test func passwordPolicyAndEnterpriseListingsDoNotFail() async throws {
        let server = try TestServer.require()
        try await server.withClient { client in
            _ = try await client.security.passwordPolicyVariables()
            _ = try await client.security.encryptionVariables()
            _ = try await client.security.encryptedTables()
            _ = try await client.security.auditPluginInstalled()
            _ = try await client.security.firewallPluginInstalled()
            _ = try await client.security.maskingComponentInstalled()
        }
    }
}
