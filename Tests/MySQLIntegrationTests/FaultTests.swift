import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import MySQLKit
import MySQLKitTesting
import Testing

/// The server through a Toxiproxy (`MYSQL_TEST_PROXY_URL`), whose HTTP API (`MYSQL_TEST_PROXY_CONTROL`)
/// adds latency, drops the link or swallows traffic.
@Suite(.testServer(TestServer.proxyVariable), .serialized, .disabled(if: systemConnectorOnLinux, "Ubuntu's GnuTLS Connector/C can't interrupt a stalled read: tashda/mysql-wire#3"))
struct FaultTests {
    /// Toxiproxy's HTTP API, for the one proxy in front of the server.
    struct Toxiproxy {
        let base: URL

        static func fromEnvironment() throws -> Toxiproxy {
            guard let text = ProcessInfo.processInfo.environment[TestServer.proxyControlVariable], let url = URL(string: text) else {
                throw TestServerError.missing(variable: TestServer.proxyControlVariable)
            }
            return Toxiproxy(base: url)
        }

        @discardableResult
        func send(_ method: String, _ path: String, _ body: [String: Any]? = nil) async throws -> Data {
            var request = URLRequest(url: base.appendingPathComponent(path))
            request.httpMethod = method
            if let body {
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw ToxiproxyError(message: "\(method) \(path): \(status) \(String(decoding: data, as: UTF8.self))")
            }
            return data
        }

        /// The proxy's name (the lab and the CI fixture each start exactly one).
        func proxyName() async throws -> String {
            let data = try await send("GET", "proxies")
            let proxies = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
            guard let name = proxies.keys.sorted().first else { throw ToxiproxyError(message: "no proxy") }
            return name
        }

        func addToxic(_ type: String, _ attributes: [String: Any], stream: String = "downstream") async throws {
            let name = try await proxyName()
            try await send("POST", "proxies/\(name)/toxics",
                           ["name": "\(type)_\(stream)", "type": type, "stream": stream, "attributes": attributes])
        }

        func setEnabled(_ enabled: Bool) async throws {
            let name = try await proxyName()
            try await send("POST", "proxies/\(name)", ["enabled": enabled])
        }

        /// Removes every toxic and enables every proxy.
        func reset() async throws { try await send("POST", "reset") }
    }

    actor Finished {
        var value = false
        func set() { value = true }
    }

    struct ToxiproxyError: Error, CustomStringConvertible { let message: String; var description: String { message } }

    /// Runs `body` with the proxy reset before and after, so one test's faults never leak into the next.
    static func withFaults(_ body: (Toxiproxy) async throws -> Void) async throws {
        let proxy = try Toxiproxy.fromEnvironment()
        try await proxy.reset()
        do {
            try await body(proxy)
            try await proxy.reset()
        } catch {
            try? await proxy.reset()
            throw error
        }
    }

    @Test func queriesWorkThroughTheProxy() async throws {
        let server = try TestServer.require()
        try await Self.withFaults { _ in
            try await server.withClient { client async throws in
                #expect(try await client.simpleQuery("SELECT 1 AS v").first?.column("v")?.int == 1)
            }
        }
    }

    @Test func slowLinkStillWorks() async throws {
        let server = try TestServer.require()
        try await Self.withFaults { proxy in
            try await server.withClient { client async throws in
                _ = try await client.simpleQuery("SELECT 1")
                try await proxy.addToxic("latency", ["latency": 400])
                let started = ContinuousClock.now
                #expect(try await client.simpleQuery("SELECT 2 AS v").first?.column("v")?.int == 2)
                #expect(ContinuousClock.now - started >= .milliseconds(400))
            }
        }
    }

    /// The link drops: the call in flight fails (it is never re-run), and once the link is back the
    /// next call reconnects by itself.
    @Test func droppedLinkFailsTheCallAndRecovers() async throws {
        let server = try TestServer.require()
        try await Self.withFaults { proxy in
            try await server.withClient { client async throws in
                _ = try await client.simpleQuery("SELECT 1")
                let inFlight = Task { try await client.simpleQuery("SELECT SLEEP(5)") }
                try await Task.sleep(for: .milliseconds(300))
                try await proxy.setEnabled(false)
                await #expect(throws: (any Error).self) { _ = try await inFlight.value }
                try await proxy.setEnabled(true)
                #expect(try await client.simpleQuery("SELECT 3 AS v").first?.column("v")?.int == 3)
            }
        }
    }

    @Test func resetConnectionIsAnErrorNotAHang() async throws {
        let server = try TestServer.require()
        try await Self.withFaults { proxy in
            try await server.withClient { client async throws in
                _ = try await client.simpleQuery("SELECT 1")
                try await proxy.addToxic("reset_peer", ["timeout": 0])
                let started = ContinuousClock.now
                await #expect(throws: (any Error).self) { _ = try await client.simpleQuery("SELECT 2") }
                #expect(ContinuousClock.now - started < .seconds(10))
            }
        }
    }

    /// The proxy accepts the connection and passes nothing on: connecting fails within the connect timeout.
    @Test func silentServerFailsWithinTheConnectTimeout() async throws {
        let server = try TestServer.require()
        try await Self.withFaults { proxy in
            try await proxy.addToxic("timeout", ["timeout": 0])
            let client = server.client(server.configuration(connectTimeoutSeconds: 2))
            defer { Task { await client.close() } }
            let started = ContinuousClock.now
            await #expect(throws: MySQLWireError.self) { _ = try await client.simpleQuery("SELECT 1") }
            #expect(ContinuousClock.now - started < .seconds(6))
        }
    }

    /// The link goes silent after login. Nothing bounds a statement's wait yet (no read deadline, no
    /// TCP keepalive), so the call waits until the client is closed.
    @Test func silentLinkAfterLoginIsDetected() async throws {
        let server = try TestServer.require()
        try await Self.withFaults { proxy in
            let client = server.client()
            _ = try await client.simpleQuery("SELECT 1")
            try await proxy.addToxic("timeout", ["timeout": 0])
            let call = Task { try await client.simpleQuery("SELECT 2") }
            // Poll rather than wait on the call: a task group would wait for it as well.
            let finishedFlag = Finished()
            Task {
                _ = try? await call.value
                await finishedFlag.set()
            }
            var detected = false
            for _ in 0..<32 where !detected {
                try await Task.sleep(for: .milliseconds(250))
                detected = await finishedFlag.value
            }
            withKnownIssue("A silent connection is not detected: statements have no deadline and keepAliveInterval is unused") {
                #expect(detected, "the statement was still waiting after 8 seconds")
            }
            await client.close()  // ends the waiting call
        }
    }
}
