import Foundation
import MySQLKit
import MySQLKitTesting
import Testing

/// Views, stored routines, triggers and events.
@Suite(.testServer)
struct ProgrammabilityTests {
    static func makeOrders(_ client: MySQLClient, _ schema: String) async throws {
        try await client.admin.createTable(schema: schema, name: "orders", columns: [
            MySQLColumnDefinition(name: "id", dataType: "INT", isNullable: false, isAutoIncrement: true),
            MySQLColumnDefinition(name: "total", dataType: "DECIMAL(10,2)", isNullable: false),
        ], primaryKey: ["id"])
        try await client.admin.createTable(schema: schema, name: "audit", columns: [
            MySQLColumnDefinition(name: "order_id", dataType: "INT"),
            MySQLColumnDefinition(name: "action", dataType: "VARCHAR(10)"),
        ])
    }

    @Test func viewsWithOptions() async throws {
        let server = try TestServer.require()
        try await server.withSchema { client, schema in
            try await Self.makeOrders(client, schema)
            try await client.views.createView(schema: schema, name: "big_orders",
                                              definitionSQL: "SELECT id, total FROM `\(schema)`.orders WHERE total > 100",
                                              algorithm: .merge, sqlSecurity: .invoker, checkOption: .cascaded)
            #expect(try await client.metadata.listViews(in: schema).map(\.name) == ["big_orders"])
            let definition = try await client.metadata.objectDefinition(named: "big_orders", schema: schema, kind: .view)
            #expect(definition.uppercased().contains("SQL SECURITY INVOKER"))
            #expect(definition.uppercased().contains("CASCADED CHECK OPTION"))

            // WITH CHECK OPTION refuses rows the view would not show.
            await #expect(throws: (any Error).self) {
                _ = try await client.simpleQuery("INSERT INTO `\(schema)`.big_orders (total) VALUES (5)")
            }
            try await client.views.alterView(schema: schema, name: "big_orders", definitionSQL: "SELECT id FROM `\(schema)`.orders")
            #expect(try await client.metadata.listColumns(in: "big_orders", schema: schema).map(\.name) == ["id"])
            try await client.views.createView(schema: schema, name: "big_orders", definitionSQL: "SELECT total FROM `\(schema)`.orders",
                                              replace: true)
            #expect(try await client.metadata.listColumns(in: "big_orders", schema: schema).map(\.name) == ["total"])
            try await client.views.dropView(schema: schema, name: "big_orders")
            #expect(try await client.metadata.listViews(in: schema).isEmpty)
        }
    }

    @Test func functionsAndProcedures() async throws {
        let server = try TestServer.require()
        try await server.withSchema { client, schema in
            try await Self.makeOrders(client, schema)
            try await client.routines.createRoutine(schema: schema, name: "with_tax", kind: .function,
                                                    parametersSQL: "amount DECIMAL(10,2)", returnsSQL: "DECIMAL(10,2)",
                                                    characteristicsSQL: "DETERMINISTIC NO SQL", bodySQL: "RETURN amount * 1.25")
            try await client.routines.createRoutine(schema: schema, name: "add_order", kind: .procedure,
                                                    parametersSQL: "IN amount DECIMAL(10,2), OUT new_id INT",
                                                    bodySQL: "BEGIN INSERT INTO orders (total) VALUES (amount); SET new_id = LAST_INSERT_ID(); END")

            #expect(try await client.metadata.listFunctions(in: schema).map(\.name) == ["with_tax"])
            #expect(try await client.metadata.listProcedures(in: schema).map(\.name) == ["add_order"])
            #expect(try await client.metadata.listRoutines(in: schema).count == 2)

            let taxed = try await client.simpleQuery("SELECT `\(schema)`.with_tax(100) AS v")
            #expect(taxed.first?.column("v")?.string == "125.00")

            // A procedure with an OUT parameter, called on one session.
            try await client.metadata.selectDatabase(schema)
            _ = try await client.simpleQuery("CALL add_order(40, @new_id)")
            #expect(try await client.simpleQuery("SELECT @new_id AS id").first?.column("id")?.int == 1)

            // Definitions come from the routine's own schema, whatever the session's database is.
            try await client.metadata.selectDatabase("mysql")
            let function = try await client.metadata.objectDefinition(named: "with_tax", schema: schema, kind: .function)
            #expect(function.contains("RETURN amount * 1.25"))
            let procedure = try await client.metadata.objectDefinition(named: "add_order", schema: schema, kind: .procedure)
            #expect(procedure.contains("LAST_INSERT_ID"))

            try await client.routines.dropRoutine(schema: schema, name: "with_tax", kind: .function)
            try await client.routines.dropRoutine(schema: schema, name: "add_order", kind: .procedure)
            #expect(try await client.metadata.listRoutines(in: schema).isEmpty)
        }
    }

    @Test func triggersRunAndAreListed() async throws {
        let server = try TestServer.require()
        try await server.withSchema { client, schema in
            try await Self.makeOrders(client, schema)
            try await client.triggers.createTrigger(schema: schema, name: "orders_ai", timing: .after, event: .insert, table: "orders",
                                                    bodySQL: "INSERT INTO `\(schema)`.audit VALUES (NEW.id, 'insert')")
            try await client.triggers.createTrigger(schema: schema, name: "orders_bu", timing: .before, event: .update, table: "orders",
                                                    bodySQL: "SET NEW.total = GREATEST(NEW.total, 0)")
            _ = try await client.bulk.insert(into: "orders", schema: schema, columns: ["total"], rows: [[MySQLData(double: 10)]])
            _ = try await client.simpleQuery("UPDATE `\(schema)`.orders SET total = -5")
            #expect(try await client.metadata.exactRowCount(schema: schema, table: "audit") == 1)
            #expect(try await client.simpleQuery("SELECT total FROM `\(schema)`.orders").first?.column("total")?.string == "0.00")

            let triggers = try await client.metadata.listTriggers(in: schema)
            #expect(Set(triggers.map(\.name)) == ["orders_ai", "orders_bu"])
            let afterInsert = try #require(triggers.first { $0.name == "orders_ai" })
            #expect(afterInsert.table == "orders")
            #expect(afterInsert.timing == "AFTER")
            #expect(afterInsert.event == "INSERT")
            try await client.metadata.selectDatabase("mysql")
            let definition = try await client.metadata.objectDefinition(named: "orders_bu", schema: schema, kind: .trigger)
            #expect(definition.contains("GREATEST"))

            try await client.triggers.dropTrigger(schema: schema, name: "orders_ai")
            try await client.triggers.dropTrigger(schema: schema, name: "orders_bu")
            #expect(try await client.metadata.listTriggers(in: schema).isEmpty)
        }
    }

    @Test func eventsAreCreatedAlteredAndListed() async throws {
        let server = try TestServer.require()
        try await server.withSchema { client, schema in
            try await Self.makeOrders(client, schema)
            try await client.events.createEvent(schema: schema, name: "purge", scheduleSQL: "EVERY 1 DAY",
                                                bodySQL: "DELETE FROM `\(schema)`.audit", enabled: false)
            var events = try await client.metadata.listEvents(in: schema)
            #expect(events.map(\.name) == ["purge"])
            #expect(events.first?.status == "DISABLED")
            try await client.events.alterEvent(schema: schema, name: "purge", scheduleSQL: "EVERY 2 HOUR", enabled: true)
            events = try await client.metadata.listEvents(in: schema)
            #expect(events.first?.status == "ENABLED")
            try await client.metadata.selectDatabase("mysql")
            let definition = try await client.metadata.objectDefinition(named: "purge", schema: schema, kind: .event)
            #expect(definition.contains("2 HOUR"))
            try await client.events.dropEvent(schema: schema, name: "purge")
            #expect(try await client.metadata.listEvents(in: schema).isEmpty)
        }
    }
}
