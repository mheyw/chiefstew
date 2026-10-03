import Foundation

/// One notification to post. `id` is stable per waiting item, so a reminder replaces the
/// earlier banner instead of stacking a second one, and resolving the item can withdraw it.
public struct Notice: Sendable, Equatable {
    public var id: String
    public var title: String
    public var body: String
    /// A file or folder to open when the notification is clicked.
    public var open: String?
    public var isReminder: Bool
    /// Worth knowing, not acting on: straight to Notification Centre, no banner or sound.
    public var passive: Bool

    public init(
        id: String, title: String, body: String, open: String?, isReminder: Bool, passive: Bool = false
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.open = open
        self.isReminder = isReminder
        self.passive = passive
    }
}

/// What has been notified: key → last time it was sent. Persisted, so a relaunch doesn't
/// re-notify everything that was already waiting.
public struct NoticeLedger: Codable, Equatable, Sendable {
    public var sent: [String: Date] = [:]
    /// Passive notices already taken down for age, so they aren't withdrawn again or re-sent.
    public var expired: Set<String>?

    public init() {}
}

/// Board → notifications. Pure. Needs-you items notify, never progress. A teammate's unmerged
/// build gets one passive notice that goes away after `teamNoticeLifetime`.
public enum NotificationPlanner {
    public static let teamNoticeLifetime: TimeInterval = 24 * 3600

    public struct Plan: Sendable, Equatable {
        public var post: [Notice] = []
        /// Notification IDs whose item has resolved; withdraw them from Notification Centre.
        public var withdraw: [String] = []
        public var ledger: NoticeLedger
    }

    /// The key for one wait. `since` is part of it, so a gate that is approved and later
    /// re-opened counts as a new wait.
    public static func key(_ item: NeedsItem) -> String {
        "\(item.id)@\(Int(item.since.timeIntervalSince1970))"
    }

    /// - Parameter loaded: repos whose status has loaded this run. A build item missing from the
    ///   board is only withdrawn when its repo is loaded; otherwise it may just not be read yet
    ///   (at launch, or while the repo's status is failing). Agent waits are withdrawn whenever
    ///   they're gone, since agent state is kept across launches.
    /// - Parameter registered: the registered repos, when known. An item for any other repo can
    ///   only have come from events, so it's withdrawn as soon as it's gone.
    public static func plan(
        board: Board, ledger: NoticeLedger, settings: Preferences, now: Date, loaded: Set<String>,
        registered: Set<String>? = nil
    ) -> Plan {
        var plan = Plan(ledger: ledger)
        var live = Set<String>()
        let reminder = TimeInterval(settings.reminderMinutes * 60)

        for item in board.needsYou {
            let key = key(item)
            live.insert(key)
            guard enabled(item, settings) else { continue }
            if let last = ledger.sent[key] {
                guard case .gate = item.kind, reminder > 0, now.timeIntervalSince(last) >= reminder
                else { continue }
                plan.post.append(notice(item, key: key, now: now, reminder: true))
            } else {
                plan.post.append(notice(item, key: key, now: now, reminder: false))
            }
            plan.ledger.sent[key] = now
        }

        for item in board.team {
            let key = key(item)
            live.insert(key)
            guard settings.notifyTeam else { continue }
            if let sent = ledger.sent[key] {
                if now.timeIntervalSince(sent) >= teamNoticeLifetime, ledger.expired?.contains(key) != true {
                    plan.withdraw.append(key)
                    plan.ledger.expired = (plan.ledger.expired ?? []).union([key])
                }
                continue
            }
            plan.post.append(teamNotice(item, key: key, now: now))
            plan.ledger.sent[key] = now
        }

        for key in ledger.sent.keys where !live.contains(key) {
            let repo = key.components(separatedBy: "#").first ?? ""
            let fromEvents = registered.map { !$0.contains(repo) } ?? false
            guard key.hasPrefix("agent-") || loaded.contains(repo) || fromEvents else { continue }
            plan.withdraw.append(key)
            plan.ledger.sent[key] = nil
            plan.ledger.expired?.remove(key)
        }
        if plan.ledger.expired?.isEmpty == true { plan.ledger.expired = nil }
        plan.withdraw.sort()
        return plan
    }

    static func enabled(_ item: NeedsItem, _ s: Preferences) -> Bool {
        switch item.kind {
        case .gate: s.notifyGates
        case .agent: s.notifyAgents
        case .unmerged: s.notifyUnmerged
        }
    }

    static func teamNotice(_ item: NeedsItem, key: String, now: Date) -> Notice {
        let ago = Durations.ago(now.timeIntervalSince(item.since))
        let num = item.card?.num ?? ""
        let name = item.card.flatMap { $0.slug.isEmpty ? nil : $0.slug } ?? item.repoName
        return Notice(
            id: key, title: "\(num) closed, not merged",
            body: "\(item.card?.author ?? "A teammate") closed \(name) \(ago). It isn't in main yet.",
            open: nil, isReminder: false, passive: true)
    }

    static func notice(_ item: NeedsItem, key: String, now: Date, reminder: Bool) -> Notice {
        let waited = Durations.short(now.timeIntervalSince(item.since))
        let who = item.card.flatMap { $0.slug.isEmpty ? nil : $0.slug } ?? item.repoName
        switch item.kind {
        case .gate(let gate):
            let num = item.card?.num ?? ""
            return Notice(
                id: key, title: "\(num) needs you",
                body: "\(gate.title) gate · \(who)" + (reminder ? " · waiting \(waited)" : ""),
                open: gate.artefact ?? item.worktree, isReminder: reminder)
        case .agent(let message, let name):
            let title = item.card.map { "\($0.num) needs you" } ?? "\(name) needs you"
            return Notice(
                id: key, title: title,
                body: "\(message ?? "\(name) is waiting for your input") · \(who)",
                open: item.worktree, isReminder: reminder)
        case .unmerged:
            let num = item.card?.num ?? ""
            return Notice(
                id: key, title: "\(num) isn't merged",
                body: "\(who) closed \(Durations.ago(now.timeIntervalSince(item.since))). Merge it today.", open: item.worktree,
                isReminder: reminder)
        }
    }
}
