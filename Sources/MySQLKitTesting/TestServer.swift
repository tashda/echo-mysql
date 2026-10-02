import Foundation
import Logging
import MySQLKit
import Testing

/// The server a test runs against, from one URL variable (see `TESTING.md`).
///
/// | Variable | Server |
/// |---|---|
/// | `MYSQL_TEST_URL` | a plain MySQL or MariaDB server |
/// | `MYSQL_TEST_TLS_URL` | a server that requires TLS; the URL carries the mode, CA and client certificate |
/// | `MYSQL_TEST_REPLICA_URL` | a replica of the `MYSQL_TEST_URL` server |
/// | `MYSQL_TEST_PROXY_URL`, `MYSQL_TEST_PROXY_CONTROL` | the server through a Toxiproxy, and the proxy's HTTP API |
///
/// A suite marked `.testServer` (or `.testServer("MYSQL_TEST_TLS_URL")`) is skipped when its
/// variable is not set, and fails instead when `MYSQL_TEST_REQUIRED=1`.
public struct TestServer: Sendable {
    public static let defaultVariable = "MYSQL_TEST_URL"
    public static let tlsVariable = "MYSQL_TEST_TLS_URL"
    public static let replicaVariable = "MYSQL_TEST_REPLICA_URL"
    public static let proxyVariable = "MYSQL_TEST_PROXY_URL"
    public static let proxyControlVariable = "MYSQL_TEST_PROXY_CONTROL"
    public static let requiredVariable = "MYSQL_TEST_REQUIRED"

    /// The variable the server came from.
    public let variable: String
    public let configuration: MySQLConfiguration

    /// The server of the running suite or test (set by the `.testServer` trait).
    @TaskLocal public static var current: TestServer?

    public init(variable: String, configuration: MySQLConfiguration) {
        self.variable = variable
        self.configuration = configuration
    }

    /// The server named by `variable`, or nil when it is not set (or does not parse).
    public static func url(_ variable: String = defaultVariable) -> TestServer? {
        try? load(variable)
    }

    /// The server named by `variable`; nil when it is not set, an error when it does not parse.
    public static func load(_ variable: String = defaultVariable,
                            environment: [String: String] = ProcessInfo.processInfo.environment) throws -> TestServer? {
        guard let url = environment[variable], !url.isEmpty else { return nil }
        do {
            return TestServer(variable: variable, configuration: try MySQLConfiguration(testURL: url))
        } catch {
            throw TestServerError.invalidURL(variable: variable, reason: "\(error)")
        }
    }

    /// Whether a missing server fails the run (`MYSQL_TEST_REQUIRED=1`), so CI cannot pass by skipping.
    public static func isRequired(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[requiredVariable] == "1"
    }

    /// The suite's server (`.testServer`), or a failure that says which variable to set.
    public static func require() throws -> TestServer {
        guard let current else { throw TestServerError.noCurrentServer }
        return current
    }

    // MARK: - Connecting

    /// This server's configuration with what a test changes.
    public func configuration(
        username: String? = nil,
        password: String?? = nil,
        database: String?? = nil,
        tlsMode: MySQLWireTLSMode? = nil,
        host: String? = nil,
        port: Int? = nil,
        connectTimeoutSeconds: Int? = nil,
        clientCertificatePath: String?? = nil,
        clientKeyPath: String?? = nil
    ) -> MySQLConfiguration {
        let base = configuration
        return MySQLConfiguration(
            host: host ?? base.host,
            port: port ?? base.port,
            username: username ?? base.username,
            password: password ?? base.password,
            database: database ?? base.database,
            tlsMode: tlsMode ?? base.tlsMode,
            connectTimeoutSeconds: connectTimeoutSeconds ?? base.connectTimeoutSeconds,
            keepAliveInterval: base.keepAliveInterval,
            clientCertificatePath: clientCertificatePath ?? base.clientCertificatePath,
            clientKeyPath: clientKeyPath ?? base.clientKeyPath
        )
    }

    /// A client for this server (or `configuration`). The caller closes it.
    public func client(_ configuration: MySQLConfiguration? = nil, label: String = "echo-mysql.tests") -> MySQLClient {
        MySQLClient(configuration: configuration ?? self.configuration, logger: Logger(label: label))
    }

    /// Runs `body` with a client and closes it afterwards.
    public func withClient<T: Sendable>(
        _ configuration: MySQLConfiguration? = nil,
        _ body: (MySQLClient) async throws -> T
    ) async throws -> T {
        let client = client(configuration)
        do {
            let value = try await body(client)
            await client.close()
            return value
        } catch {
            await client.close()
            throw error
        }
    }

    /// Runs `body` with a client and a new, empty schema, and drops both afterwards (also when
    /// `body` throws). Each test works in its own schema, so suites run in parallel.
    public func withSchema<T: Sendable>(
        _ name: String = #function,
        _ body: (MySQLClient, String) async throws -> T
    ) async throws -> T {
        let client = client()
        let schema = Self.uniqueName(name)
        do {
            try await client.admin.createDatabase(name: schema)
            let value = try await body(client, schema)
            try await client.admin.dropDatabase(name: schema)
            await client.close()
            return value
        } catch {
            try? await client.admin.dropDatabase(name: schema)
            await client.close()
            throw error
        }
    }

    /// What the server is, for expectations that differ between MySQL and MariaDB or versions.
    public func flavor() async throws -> MySQLServerFlavor {
        try await withClient { try await $0.serverFlavor() }
    }

    /// A name for a schema, user, role or other object, unique to this run: `mwt_<base>_<random>`,
    /// at most 32 characters (MySQL's limit for user names), lower case.
    public static func uniqueName(_ base: String) -> String {
        let prefix = "mwt_"
        let suffix = String(UInt32.random(in: 0...UInt32.max), radix: 36)
        let cleaned = String(base.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" })
        return prefix + String(cleaned.prefix(32 - prefix.count - suffix.count - 1)) + "_" + suffix
    }
}

public enum TestServerError: Error, CustomStringConvertible {
    case missing(variable: String)
    case invalidURL(variable: String, reason: String)
    case noCurrentServer

    public var description: String {
        switch self {
        case .missing(let variable):
            return "\(variable) is not set and \(TestServer.requiredVariable)=1 requires it (see TESTING.md)"
        case .invalidURL(let variable, let reason):
            return "\(variable) does not parse: \(reason)"
        case .noCurrentServer:
            return "No test server: mark the suite or test with .testServer"
        }
    }
}

/// Provides `TestServer.current` from a URL variable, or skips (fails with `MYSQL_TEST_REQUIRED=1`)
/// when the variable is not set.
public struct TestServerTrait: SuiteTrait, TestTrait, TestScoping {
    public let variable: String

    public var isRecursive: Bool { false }

    public func prepare(for test: Test) async throws {
        if try TestServer.load(variable) != nil { return }
        if TestServer.isRequired() { throw TestServerError.missing(variable: variable) }
        try await ConditionTrait.disabled(Comment(rawValue: "Set \(variable) to run this (see TESTING.md)")).prepare(for: test)
    }

    public func scopeProvider(for test: Test, testCase: Test.Case?) -> TestServerTrait? {
        if test.isSuite { return self }
        return testCase == nil ? nil : self
    }

    public func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        guard let server = try TestServer.load(variable) else { throw TestServerError.missing(variable: variable) }
        try await TestServer.$current.withValue(server) { try await function() }
    }
}

extension Trait where Self == TestServerTrait {
    /// The `MYSQL_TEST_URL` server.
    public static var testServer: Self { TestServerTrait(variable: TestServer.defaultVariable) }

    /// The server named by `variable`, e.g. `MYSQL_TEST_TLS_URL`.
    public static func testServer(_ variable: String) -> Self { TestServerTrait(variable: variable) }
}

/// MySQL or MariaDB, and the version.
public struct MySQLServerFlavor: Sendable, Hashable, CustomStringConvertible {
    public let version: String
    public let isMariaDB: Bool
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(version: String) {
        self.version = version
        isMariaDB = version.localizedCaseInsensitiveContains("mariadb")
        let numbers = version.split(whereSeparator: { !$0.isNumber && $0 != "." }).first.map {
            $0.split(separator: ".").compactMap { Int($0) }
        } ?? []
        major = numbers.first ?? 0
        minor = numbers.count > 1 ? numbers[1] : 0
        patch = numbers.count > 2 ? numbers[2] : 0
    }

    public var isMySQL: Bool { !isMariaDB }

    /// Whether this server is at least `major.minor.patch` (of its own kind: MySQL or MariaDB).
    public func atLeast(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) -> Bool {
        (self.major, self.minor, self.patch) >= (major, minor, patch)
    }

    public var description: String { version }
}

public extension MySQLClient {
    /// MySQL or MariaDB, and the version.
    func serverFlavor() async throws -> MySQLServerFlavor {
        let rows = try await simpleQuery("SELECT VERSION() AS version")
        return MySQLServerFlavor(version: rows.first?.column("version")?.string ?? "")
    }
}
