import Foundation

/// The owner's settings, stored as JSON in UserDefaults. Decoding is lenient so a field added
/// later falls back to its default instead of resetting everything.
public struct Preferences: Codable, Equatable, Sendable {
    /// Which needs-you items send a notification.
    public var notifyGates = true
    public var notifyAgents = true
    public var notifyUnmerged = true
    /// A teammate's build is closed but not merged: one quiet notice.
    public var notifyTeam = true
    /// A build of yours runs past its time budget: one quiet notice.
    public var notifyBudget = true
    /// Re-notify a still-waiting gate this often. 0 turns reminders off.
    public var reminderMinutes = 30
    /// Bundle ID of the app "Open worktree" uses; nil is Finder.
    public var worktreeApp: String?
    /// Overrides the login-shell lookup for `node`.
    public var nodePath: String?
    /// What to update to: tagged releases (the team default) or the latest `main` (developers).
    public var updateChannel: UpdateChannel = .releases
    /// What to do when an update is available.
    public var updateMode: UpdateMode = .automatic

    public init() {}

    enum CodingKeys: String, CodingKey {
        case notifyGates, notifyAgents, notifyUnmerged, notifyTeam, notifyBudget, reminderMinutes, worktreeApp, nodePath
        case updateChannel, updateMode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        notifyGates = (try? c.decodeIfPresent(Bool.self, forKey: .notifyGates)) ?? nil ?? d.notifyGates
        notifyAgents = (try? c.decodeIfPresent(Bool.self, forKey: .notifyAgents)) ?? nil ?? d.notifyAgents
        notifyUnmerged =
            (try? c.decodeIfPresent(Bool.self, forKey: .notifyUnmerged)) ?? nil ?? d.notifyUnmerged
        notifyTeam = (try? c.decodeIfPresent(Bool.self, forKey: .notifyTeam)) ?? nil ?? d.notifyTeam
        notifyBudget = (try? c.decodeIfPresent(Bool.self, forKey: .notifyBudget)) ?? nil ?? d.notifyBudget
        reminderMinutes =
            (try? c.decodeIfPresent(Int.self, forKey: .reminderMinutes)) ?? nil ?? d.reminderMinutes
        worktreeApp = (try? c.decodeIfPresent(String.self, forKey: .worktreeApp)) ?? nil
        nodePath = (try? c.decodeIfPresent(String.self, forKey: .nodePath)) ?? nil
        updateChannel = (try? c.decodeIfPresent(UpdateChannel.self, forKey: .updateChannel)) ?? nil ?? d.updateChannel
        updateMode = (try? c.decodeIfPresent(UpdateMode.self, forKey: .updateMode)) ?? nil ?? d.updateMode
    }

    public static let reminderChoices = [0, 15, 30, 60, 120]
}

public enum UpdateChannel: String, Codable, Sendable, CaseIterable {
    /// Tagged releases (`v0.3.0`), fetched from GitHub. What teammates get.
    case releases
    /// Whatever is on `main` in the local clone: for whoever develops Chief Stew.
    case main
}

public enum UpdateMode: String, Codable, Sendable, CaseIterable {
    case automatic, ask, off
}
