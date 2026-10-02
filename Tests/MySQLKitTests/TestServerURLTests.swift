import MySQLKit
import MySQLKitTesting
import Testing

@Suite struct TestServerURLTests {
    @Test func plainServerWithPreferredTLS() throws {
        let configuration = try MySQLConfiguration(testURL: "mysql://root:pass@localhost:3306/?ssl-mode=PREFERRED")
        #expect(configuration.host == "localhost")
        #expect(configuration.port == 3306)
        #expect(configuration.username == "root")
        #expect(configuration.password == "pass")
        #expect(configuration.database == nil)
        #expect(configuration.tlsMode == .preferred)
        #expect(configuration.clientCertificatePath == nil)
    }

    @Test func verifyIdentityWithCAAndClientCertificate() throws {
        let configuration = try MySQLConfiguration(
            testURL: "mysql://root:pass@host:3306/?ssl-mode=VERIFY_IDENTITY&ssl-ca=/ca.pem&ssl-cert=/c.pem&ssl-key=/k.pem")
        #expect(configuration.host == "host")
        #expect(configuration.tlsMode == .verifyIdentity(caCertificatePath: "/ca.pem"))
        #expect(configuration.clientCertificatePath == "/c.pem")
        #expect(configuration.clientKeyPath == "/k.pem")
    }

    @Test func everySSLMode() throws {
        func mode(_ query: String) throws -> MySQLWireTLSMode {
            try MySQLConfiguration(testURL: "mysql://u:p@h/\(query)").tlsMode
        }
        #expect(try mode("") == .preferred)
        #expect(try mode("?ssl-mode=DISABLED") == .disabled)
        #expect(try mode("?ssl-mode=preferred") == .preferred)
        #expect(try mode("?ssl-mode=REQUIRED") == .required)
        #expect(try mode("?ssl-mode=VERIFY_CA&ssl-ca=/ca.pem") == .verifyCA(caCertificatePath: "/ca.pem"))
        #expect(try mode("?ssl-mode=VERIFY_IDENTITY") == .verifyIdentity(caCertificatePath: nil))
        #expect(throws: MySQLTestURLError.missingCA("VERIFY_CA")) { try mode("?ssl-mode=VERIFY_CA") }
        #expect(throws: MySQLTestURLError.unknownSSLMode("SOMETIMES")) { try mode("?ssl-mode=SOMETIMES") }
    }

    @Test func pathNamesTheDatabaseAndPortDefaults() throws {
        let configuration = try MySQLConfiguration(testURL: "mariadb://app:secret@db.example.com/sakila?connect-timeout=3")
        #expect(configuration.port == 3306)
        #expect(configuration.database == "sakila")
        #expect(configuration.connectTimeoutSeconds == 3)
    }

    @Test func percentEncodedUserAndPassword() throws {
        // p@ss:w/rd%? and a user with an @ in it.
        let configuration = try MySQLConfiguration(testURL: "mysql://lab%40user:p%40ss%3Aw%2Frd%25%3F@127.0.0.1:3307/")
        #expect(configuration.username == "lab@user")
        #expect(configuration.password == "p@ss:w/rd%?")
        #expect(configuration.port == 3307)
    }

    @Test func noPasswordAndIPv6Host() throws {
        let configuration = try MySQLConfiguration(testURL: "mysql://root@[::1]:3306/")
        #expect(configuration.password == nil)
        #expect(configuration.host == "::1")
    }

    @Test func malformedURLsAreRejected() {
        #expect(throws: MySQLTestURLError.unsupportedScheme("postgres")) { try MySQLConfiguration(testURL: "postgres://u:p@h:5432/") }
        #expect(throws: MySQLTestURLError.missingUser) { try MySQLConfiguration(testURL: "mysql://h:3306/") }
        #expect(throws: MySQLTestURLError.incompleteClientCertificate) {
            try MySQLConfiguration(testURL: "mysql://u:p@h/?ssl-mode=REQUIRED&ssl-cert=/c.pem")
        }
    }

    @Test func missingVariableIsNoServer() throws {
        #expect(try TestServer.load("MYSQL_TEST_URL", environment: [:]) == nil)
        #expect(try TestServer.load("MYSQL_TEST_URL", environment: ["MYSQL_TEST_URL": ""]) == nil)
        let server = try #require(try TestServer.load("MYSQL_TEST_TLS_URL",
                                                      environment: ["MYSQL_TEST_TLS_URL": "mysql://root:x@h:1/?ssl-mode=REQUIRED"]))
        #expect(server.variable == "MYSQL_TEST_TLS_URL")
        #expect(server.configuration.tlsMode == .required)
        #expect(throws: TestServerError.self) { try TestServer.load("MYSQL_TEST_URL", environment: ["MYSQL_TEST_URL": "nonsense"]) }
    }

    @Test func requiredOnlyWhenSetToOne() {
        #expect(TestServer.isRequired(environment: ["MYSQL_TEST_REQUIRED": "1"]))
        #expect(!TestServer.isRequired(environment: ["MYSQL_TEST_REQUIRED": "0"]))
        #expect(!TestServer.isRequired(environment: [:]))
    }

    @Test func uniqueNamesFitMySQLsUserNameLimit() {
        let name = TestServer.uniqueName("a very long test name that goes on and on()")
        #expect(name.count <= 32)
        #expect(name.hasPrefix("mwt_a_very_long"))
        #expect(TestServer.uniqueName("x") != TestServer.uniqueName("x"))
    }

    @Test func flavorReadsMySQLAndMariaDBVersions() {
        let mariaDB = MySQLServerFlavor(version: "11.8.3-MariaDB-ubu2404")
        #expect(mariaDB.isMariaDB && mariaDB.atLeast(11, 8) && !mariaDB.atLeast(11, 9))
        let mySQL = MySQLServerFlavor(version: "8.4.6")
        #expect(mySQL.isMySQL && mySQL.atLeast(8, 0, 23) && !mySQL.atLeast(9))
    }
}

/// The trait itself: without the variable a suite is skipped (this suite's test never runs when
/// MYSQL_TEST_URL is unset); with it, the test sees the server.
@Suite(.testServer)
struct TestServerTraitTests {
    @Test func providesTheCurrentServer() throws {
        let server = try TestServer.require()
        #expect(server.variable == "MYSQL_TEST_URL")
    }
}
