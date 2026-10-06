import Foundation

/// Lenient date parsing for the contract: ISO 8601 (with or without fractional seconds or a zone
/// offset), a date-only `YYYY-MM-DD` (local midnight), a raw progress.md `YYYY-MM-DD HH:MM`
/// (local), or unix seconds.
public enum LooseDate {
    public static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
        ] {
            let f = ISO8601DateFormatter()
            f.formatOptions = options
            if let d = f.date(from: t) { return d }
        }
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = format
            if let d = f.date(from: t) { return d }
        }
        return nil
    }

    /// `2026-10-06`, with no time of day: it parses as local midnight, which isn't when it was.
    public static func isDateOnly(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
}

/// A date field that may be an ISO string or unix seconds.
public struct FlexibleDate: Decodable, Sendable, Equatable {
    public let date: Date

    public init(_ date: Date) { self.date = date }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let n = try? c.decode(Double.self) {
            date = Date(timeIntervalSince1970: n)
        } else if let d = LooseDate.parse(try c.decode(String.self)) {
            date = d
        } else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "unparseable date")
        }
    }
}

public enum Durations {
    /// `just now`, `12 min`, `1h 42m`, `2 d`.
    public static func short(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "just now" }
        if s < 3600 { return "\(s / 60) min" }
        if s < 86400 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 86400) d"
    }

    /// `just now` or `12 min ago`.
    public static func ago(_ seconds: TimeInterval) -> String {
        let text = short(seconds)
        return text == "just now" ? text : "\(text) ago"
    }

    /// `since 6 Oct` (with the year if it isn't this one): for a start known only by its day.
    public static func sinceDay(_ day: Date, now: Date, locale: Locale = .current) -> String {
        let cal = Calendar.current
        var style = Date.FormatStyle(locale: locale).day().month(.abbreviated)
        if cal.component(.year, from: day) != cal.component(.year, from: now) { style = style.year() }
        return "since \(day.formatted(style))"
    }
}
