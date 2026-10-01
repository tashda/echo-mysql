import MySQLNIO

public extension MySQLRow {
    /// A column by name, ignoring case. MySQL 8 and later label `information_schema` columns in
    /// upper case (`COLUMN_NAME`) whatever the query wrote; MariaDB keeps the query's case.
    func field(_ name: String) -> MySQLData? {
        if let exact = column(name) { return exact }
        guard let match = columnDefinitions.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return nil }
        return column(match.name)
    }
}
