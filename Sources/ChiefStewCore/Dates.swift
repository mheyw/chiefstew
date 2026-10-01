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
}
