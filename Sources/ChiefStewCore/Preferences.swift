import Foundation

/// The owner's settings, stored as JSON in UserDefaults. Decoding is lenient so a field added
/// later falls back to its default instead of resetting everything.
public struct Preferences: Codable, Equatable, Sendable {
    /// Which needs-you items send a notification.
    public var notifyGates = true
    public var notifyAgents = true
    public var notifyUnmerged = true
    /// Re-notify a still-waiting gate this often. 0 turns reminders off.
    public var reminderMinutes = 30
    /// Bundle ID of the app "Open worktree" uses; nil is Finder.
    public var worktreeApp: String?
    /// Overrides the login-shell lookup for `node`.
    public var nodePath: String?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case notifyGates, notifyAgents, notifyUnmerged, reminderMinutes, worktreeApp, nodePath
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        notifyGates = (try? c.decodeIfPresent(Bool.self, forKey: .notifyGates)) ?? nil ?? d.notifyGates
        notifyAgents = (try? c.decodeIfPresent(Bool.self, forKey: .notifyAgents)) ?? nil ?? d.notifyAgents
        notifyUnmerged =
            (try? c.decodeIfPresent(Bool.self, forKey: .notifyUnmerged)) ?? nil ?? d.notifyUnmerged
        reminderMinutes =
            (try? c.decodeIfPresent(Int.self, forKey: .reminderMinutes)) ?? nil ?? d.reminderMinutes
        worktreeApp = (try? c.decodeIfPresent(String.self, forKey: .worktreeApp)) ?? nil
        nodePath = (try? c.decodeIfPresent(String.self, forKey: .nodePath)) ?? nil
    }

    public static let reminderChoices = [0, 15, 30, 60, 120]
}
