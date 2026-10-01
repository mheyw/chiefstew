import Foundation

/// Where Chief Stew keeps its files. See docs/event-contract.md § Locations.
public struct Paths: Sendable, Equatable {
    /// `~/Library/Application Support/Chief Stew`, or `$CHIEFSTEW_HOME` when set (tests, dev runs).
    public let home: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        if let override = environment["CHIEFSTEW_HOME"], !override.isEmpty {
            home = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Chief Stew", isDirectory: true)
        }
    }

    /// Emitters drop one JSON file per event here. Its existence means "Chief Stew is installed".
    public var inbox: URL { home.appendingPathComponent("inbox", isDirectory: true) }

    /// Touched every 60 s while the app runs. Fresh (< 180 s) means "Chief Stew is running".
    public var heartbeat: URL { home.appendingPathComponent("alive") }

    /// Agent state, kept across launches.
    public var agents: URL { home.appendingPathComponent("agents.json") }

    /// One empty file per agent session that needs input (contract § 1).
    public var waiting: URL { home.appendingPathComponent("waiting", isDirectory: true) }

    /// A session ID as a safe file name: letters, digits, `-` and `_` only.
    public static func markerName(_ session: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let name = String(session.filter { allowed.contains($0) }.prefix(128))
        return name.isEmpty ? "session" : name
    }
}
