public extension MySQLSecurityClient {
    /// Loads a server plugin from its library (`INSTALL PLUGIN name SONAME 'library'`), e.g. MariaDB's
    /// `ed25519` from `auth_ed25519`. MySQL and MariaDB both accept this form.
    func installPlugin(name: String, library: String) async throws {
        let backslashEscapes = try await backslashEscapes(for: [library])
        try await executeSecurityStatement(installPluginSQL(name: name, library: library, backslashEscapes: backslashEscapes))
    }

    func uninstallPlugin(name: String) async throws {
        try await executeSecurityStatement("UNINSTALL PLUGIN `\(name.replacingOccurrences(of: "`", with: "``"))`")
    }

    internal func installPluginSQL(name: String, library: String, backslashEscapes: Bool = true) -> String {
        "INSTALL PLUGIN `\(name.replacingOccurrences(of: "`", with: "``"))` SONAME '\(escapedSQLLiteral(library, backslashEscapes: backslashEscapes))'"
    }
}
