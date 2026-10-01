import Foundation

/// One value: a cell read from a row (the server's text, or bytes for binary columns), or a
/// statement parameter.
public struct MySQLData: Sendable, Hashable, CustomStringConvertible {
    public let type: MySQLDataType
    /// The bytes as the server sent them (text protocol), or the parameter's; nil for NULL.
    public let bytes: Data?
    /// Whether the bytes are binary (a binary column, or a parameter of bytes).
    public let isBinary: Bool

    public init(type: MySQLDataType, bytes: Data?, isBinary: Bool = false) {
        self.type = type
        self.bytes = bytes
        self.isBinary = isBinary
    }

    public static let null = MySQLData(type: .null, bytes: nil)
    public init(string: String) { self.init(type: .varString, bytes: Data(string.utf8)) }
    public init(int: Int) { self.init(type: .longlong, bytes: Data(String(int).utf8)) }
    public init(double: Double) { self.init(type: .double, bytes: Data("\(double)".utf8)) }
    public init(bool: Bool) { self.init(type: .tiny, bytes: Data((bool ? "1" : "0").utf8)) }
    /// An exact decimal, written as text (`"12.50"`).
    public init(decimal: String) { self.init(type: .newdecimal, bytes: Data(decimal.utf8)) }
    /// Bytes (BLOB, BINARY), sent as a hex literal.
    public init(data: Data) { self.init(type: .blob, bytes: data, isBinary: true) }
    /// A point in time as `DATETIME(6)` text in UTC.
    public init(date: Date) { self.init(type: .datetime, bytes: Data(MySQLDateText.format(date).utf8)) }

    public var isNull: Bool { bytes == nil }

    /// The value as text; nil for NULL.
    public var string: String? { bytes.map { String(decoding: $0, as: UTF8.self) } }
    public var int: Int? { string.flatMap { Int($0) } }
    public var int64: Int64? { string.flatMap { Int64($0) } }
    public var uint64: UInt64? { string.flatMap { UInt64($0) } }
    public var double: Double? { string.flatMap { Double($0) } }
    /// `1`/`0` (TINYINT(1)), `true`/`false`; nil otherwise.
    public var bool: Bool? {
        switch string?.lowercased() {
        case "1", "true": true
        case "0", "false": false
        default: nil
        }
    }
    public var decimal: Decimal? { string.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) } }
    /// DATE, DATETIME, TIMESTAMP text read as UTC.
    public var date: Date? { string.flatMap(MySQLDateText.parse) }
    /// The raw bytes (BLOB, BIT, GEOMETRY …); nil for NULL.
    public var data: Data? { bytes }
    /// The same as ``data`` (mysql-nio's name).
    public var buffer: Data? { bytes }

    /// A JSON column decoded into `T`.
    public func json<T: Decodable>(as type: T.Type) throws -> T? {
        guard let bytes else { return nil }
        return try JSONDecoder().decode(T.self, from: bytes)
    }

    public var description: String { string ?? "NULL" }
}

/// MySQL date and time text (`2026-10-01`, `2026-10-01 12:34:56.123456`).
enum MySQLDateText {
    private static let utc = TimeZone(identifier: "UTC") ?? .gmt

    static func parse(_ text: String) -> Date? {
        let parts = text.split(separator: " ")
        let day = parts.first.map { $0.split(separator: "-").compactMap { Int($0) } } ?? []
        guard day.count == 3, day[0] > 0, day[1] > 0, day[2] > 0 else { return nil }
        var components = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: utc, year: day[0], month: day[1], day: day[2])
        if parts.count > 1 {
            let time = parts[1].split(separator: ":")
            guard time.count == 3 else { return nil }
            components.hour = Int(time[0])
            components.minute = Int(time[1])
            let seconds = time[2].split(separator: ".")
            components.second = Int(seconds[0])
            if seconds.count > 1 {
                let fraction = String(seconds[1].prefix(9))
                components.nanosecond = (Int(fraction) ?? 0) * Int(pow(10.0, Double(9 - fraction.count)))
            }
        }
        return components.date
    }

    static func format(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let seconds = floor(date.timeIntervalSince1970)
        let micros = min(999_999, Int((date.timeIntervalSince1970 - seconds) * 1_000_000 + 0.5))
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: Date(timeIntervalSince1970: seconds))
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d.%06d", c.year ?? 1970, c.month ?? 1, c.day ?? 1, c.hour ?? 0, c.minute ?? 0, c.second ?? 0, micros)
    }
}
