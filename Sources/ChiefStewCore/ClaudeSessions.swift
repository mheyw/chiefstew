import Foundation

/// What Claude Code itself says each of its sessions is doing, from `claude agents --json`.
/// The hooks can't tell: Stop fires when the main turn ends, even while background agents work.
public struct ClaudeSessions: Sendable, Equatable {
    public enum Status: String, Sendable {
        case busy, idle, waiting
    }

    public struct Session: Sendable, Equatable {
        public var status: Status
        /// When Chief Stew saw it change to this status; nil if it already was at first sight.
        public var since: Date?
    }

    public private(set) var sessions: [String: Session] = [:]

    public init() {}

    /// Folds in a fresh report. A session missing from it has ended.
    public mutating func update(_ report: [String: Status], at now: Date) {
        var next: [String: Session] = [:]
        for (id, status) in report {
            if let old = sessions[id] {
                next[id] = old.status == status ? old : Session(status: status, since: now)
            } else {
                next[id] = Session(status: status, since: nil)
            }
        }
        sessions = next
    }

    /// `claude agents --json`: an array of sessions with `sessionId` and `status`. A status this
    /// doesn't know is left out, not guessed. Nil when the output isn't that array.
    public static func parse(_ data: Data) -> [String: Status]? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var report: [String: Status] = [:]
        for s in list {
            guard let id = s["sessionId"] as? String, let raw = s["status"] as? String,
                let status = Status(rawValue: raw)
            else { continue }
            report[id] = status
        }
        return report
    }

    /// The `claude` command: on the login PATH, else where Claude Code installs it. Apps don't
    /// see shell aliases, and the local install is often only an alias.
    public static func locate(
        path: String, home: String = NSHomeDirectory(),
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let dirs = path.split(separator: ":").map(String.init)
            + ["\(home)/.claude/local", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
        return dirs.map { ($0 as NSString).appendingPathComponent("claude") }.first(where: isExecutable)
    }
}
