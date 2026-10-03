import Foundation

/// Everything known about one registered repo: the last good status and sweep, and any error.
public struct RepoSnapshot: Sendable, Equatable {
    public var path: String
    public var status: StatusReport?
    public var statusAt: Date?
    public var statusError: RepoError?
    public var sweep: SweepReport?
    public var sweepAt: Date?
    /// The repo has no status command: only its agents are watched.
    public var agentsOnly = false

    public init(
        path: String, status: StatusReport? = nil, statusAt: Date? = nil,
        statusError: RepoError? = nil, sweep: SweepReport? = nil, sweepAt: Date? = nil
    ) {
        self.path = path
        self.status = status
        self.statusAt = statusAt
        self.statusError = statusError
        self.sweep = sweep
        self.sweepAt = sweepAt
    }

    public var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

public struct RepoError: Sendable, Equatable {
    public var message: String
    public var since: Date
    /// What the owner can do about it, if there's something specific.
    public var hint: String?

    public init(message: String, since: Date, hint: String? = nil) {
        self.message = message
        self.since = since
        self.hint = hint
    }
}

// MARK: - The view model

public enum PhaseDot: Sendable, Equatable { case done, active, waiting, pending }

public struct BuildCard: Sendable, Equatable, Identifiable {
    public var id: String  // repo path + build number
    public var repoName: String
    public var num: String
    public var slug: String
    /// The repo's route name for this build, if it has lanes.
    public var lane: String?
    public var dots: [PhaseDot]
    /// `Execute`, `Plan gate`, `Spec next`; nil when status has no phases.
    public var phaseLabel: String?
    public var tasks: TaskCount?
    public var state: String
    public var startedAt: Date?
    public var lastActivity: Date
    /// `Claude idle 9 min`, `Claude active 3 min ago`; nil with no agent events.
    public var agentLine: String?
    public var behind: Int?
    public var flags: [String]
    public var worktree: String?
    public var progress: String?
    public var url: String?
    /// The repo's last status call failed; this is the last good data.
    public var staleSince: Date?
    /// Set aside on purpose: the Current state line starts with "Parked". Shown dimmed and last,
    /// and never in the menu-bar title.
    public var parked: Bool = false
    /// An agent session in this build's checkout is mid-turn right now. On a parked build it
    /// means the build was picked up again before its Current state line said so.
    public var agentWorking: Bool = false
}

public struct NeedsItem: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case gate(GateInfo)
        /// `name`: "Claude", "Codex", "Agent".
        case agent(message: String?, name: String)
        case unmerged
    }

    public var id: String
    public var kind: Kind
    public var since: Date
    /// The build it concerns; nil for an agent outside any known build.
    public var card: BuildCard?
    public var repoName: String
    public var worktree: String?
    /// The repo's path, for reading an artefact from git.
    public var repoPath: String = ""
    /// For agent items: the session, for "Go to session".
    public var session: String?

    /// Short text for the menu bar when this is the only item.
    public var menuTitle: String {
        let num = card.map { "\($0.num) " } ?? ""
        switch kind {
        case .gate(let g): return "\(num)\(g.title) gate"
        case .agent(_, let name): return card == nil ? "\(name) waiting" : "\(num)\(name)"
        case .unmerged: return "\(num)not merged"
        }
    }
}

public struct LeftItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var repoName: String
    public var title: String
    public var details: [String]
    /// A command the owner can copy; Chief Stew never runs it.
    public var command: String?
}

public struct Problem: Sendable, Equatable, Identifiable {
    public var id: String { repoPath }
    public var repoPath: String
    public var repoName: String
    public var error: RepoError
}

/// The menu-bar item is an icon only (text there gets hidden by macOS when the menu bar is
/// full, taking the icon with it). Detail lives in the panel and notifications.
public struct MenuBarState: Sendable, Equatable {
    /// A short summary ("174 Plan gate", "2 need you"): spoken by VoiceOver, never drawn.
    public var title: String?
    /// Something needs you: the icon turns orange.
    public var attention: Bool
    /// Left-behind findings or a repo that can't be read: a small triangle on the icon.
    public var warning: Bool
    /// Work is in flight: a small dot on the icon.
    public var busy: Bool = false
}

public struct Board: Sendable, Equatable {
    public var needsYou: [NeedsItem] = []
    public var inProgress: [BuildCard] = []
    public var leftBehind: [LeftItem] = []
    public var leftNotes: [String] = []
    /// The sweep's `cleanup` commands: shown to copy, never run.
    public var leftCleanup: [String] = []
    public var sweptAt: Date?
    public var problems: [Problem] = []
    public var repoNames: [String] = []
    public var checkedAt: Date?

    public var buildCount: Int {
        Set(needsYou.compactMap { $0.card?.id } + active.map(\.id)).count
    }
    /// In-progress builds that aren't parked.
    public var active: [BuildCard] { inProgress.filter { !$0.parked } }
    public var parkedCount: Int { inProgress.count - active.count }
    public var leftCount: Int {
        leftBehind.reduce(0) { $0 + max(1, $1.details.count) }
    }

    public var header: String {
        var parts: [String] = []
        if buildCount > 0 { parts.append(buildCount == 1 ? "1 build" : "\(buildCount) builds") }
        if parkedCount > 0 { parts.append("\(parkedCount) parked") }
        if !needsYou.isEmpty { parts.append("\(needsYou.count) need\(needsYou.count == 1 ? "s" : "") you") }
        if leftCount > 0 { parts.append("\(leftCount) left behind") }
        if !problems.isEmpty {
            parts.append(problems.count == 1 ? "1 repo stale" : "\(problems.count) repos stale")
        }
        return parts.isEmpty ? "Nothing in flight" : parts.joined(separator: " · ")
    }

    public var menu: MenuBarState {
        let warning = !leftBehind.isEmpty || !problems.isEmpty
        if needsYou.count == 1 {
            return .init(title: needsYou[0].menuTitle, attention: true, warning: warning, busy: true)
        }
        if needsYou.count > 1 {
            return .init(title: "\(needsYou.count) need you", attention: true, warning: warning, busy: true)
        }
        let active = active
        guard let top = active.first else {
            return .init(title: nil, attention: false, warning: warning)
        }
        var title = top.num
        if let label = top.phaseLabel { title += " \(label)" }
        if let t = top.tasks, t.total > 0 { title += " \(t.done)/\(t.total)" }
        if active.count > 1 { title += " +\(active.count - 1)" }
        return .init(title: title, attention: false, warning: warning, busy: true)
    }
}

// MARK: - The reducer

extension Board {
    /// Status + sweep + agent state → what the panel and menu bar show. Pure.
    /// - Parameter eventGates: gates known only from events; shown for a repo whose status
    ///   can't show them (not registered, not read yet, or failing).
    public static func make(
        repos: [RepoSnapshot], agents: [AgentState], eventGates: [EventGates.Wait] = [], now: Date
    ) -> Board {
        var board = Board()
        board.repoNames = repos.map(\.name)
        board.checkedAt = repos.compactMap(\.statusAt).min()

        // One entry per build. A status may report a worktree on another branch (e.g. an agent
        // worktree branched from the build) as a second row with the same number; keep the
        // build-branch row and treat the others' worktrees as extra places its agents run.
        var builds: [(repo: RepoSnapshot, row: BuildRow, paths: [String])] = []
        for repo in repos {
            let rows = (repo.status?.builds ?? []).filter { !$0.merged }
            var seen = Set<String>()
            for row in rows where seen.insert(row.num).inserted {
                let same = rows.filter { $0.num == row.num }
                // Prefer the row whose branch carries the build's ID.
                let primary = same.first { $0.branch.contains(row.num) } ?? same[0]
                builds.append((repo, primary, same.compactMap(\.worktree) + same.flatMap(\.worktrees)))
            }
        }

        // Each agent session belongs to the build whose checkout it runs in. The emitter sends
        // the checkout root, so this is an exact match (contract § 3.3), not a prefix match:
        // nested worktrees under .claude/worktrees are separate checkouts.
        var sessionsByBuild: [String: [AgentState]] = [:]
        var loose: [AgentState] = []
        for agent in agents {
            let target = PathMatch.normalize(agent.path)
            if let b = builds.first(where: { $0.paths.contains { PathMatch.normalize($0) == target } }) {
                sessionsByBuild[cardID(b.repo, b.row), default: []].append(agent)
            } else {
                loose.append(agent)
            }
        }

        var needBuilds = Set<String>()
        for (repo, row, _) in builds {
            let id = cardID(repo, row)
            let agents = sessionsByBuild[id] ?? []
            let card = makeCard(repo: repo, row: row, agents: agents, now: now)

            // A parked build was set aside on purpose: its gate or merge doesn't need you now.
            if !card.parked {
                for gate in row.waitingGates {
                    board.needsYou.append(
                        NeedsItem(
                            id: "\(id)#gate-\(gate.gate)", kind: .gate(gate),
                            since: gate.at ?? row.lastCommitAt, card: card, repoName: repo.name,
                            worktree: row.worktree, repoPath: repo.path))
                    needBuilds.insert(id)
                }
                if row.flags.contains("closed-unmerged") {
                    board.needsYou.append(
                        NeedsItem(
                            id: "\(id)#unmerged", kind: .unmerged, since: row.lastCommitAt,
                            card: card, repoName: repo.name, worktree: row.worktree))
                    needBuilds.insert(id)
                }
            }
            // Keyed on the session alone, so the same wait keeps the same ID (and notification)
            // even if which build it matches changes.
            for agent in agents {
                guard let n = agent.needsInput else { continue }
                board.needsYou.append(
                    NeedsItem(
                        id: "agent-\(agent.session)",
                        kind: .agent(message: n.message, name: agent.displayName),
                        since: n.since, card: card, repoName: repo.name, worktree: agent.path,
                        session: agent.session))
                needBuilds.insert(id)
            }
            if !needBuilds.contains(id) { board.inProgress.append(card) }
        }
        for agent in loose {
            guard let n = agent.needsInput else { continue }
            board.needsYou.append(
                NeedsItem(
                    id: "agent-\(agent.session)",
                    kind: .agent(message: n.message, name: agent.displayName), since: n.since,
                    card: nil, repoName: URL(fileURLWithPath: agent.path).lastPathComponent,
                    worktree: agent.path, session: agent.session))
        }

        for wait in eventGates {
            let repo = repos.first { PathMatch.normalize($0.path) == wait.repo }
            if let repo, repo.status != nil, repo.statusError == nil { continue }  // status shows it
            let id = "\(wait.repo)#\(wait.build)#gate-\(wait.gate)"
            guard !board.needsYou.contains(where: { $0.id == id }) else { continue }
            let name = repo?.name ?? URL(fileURLWithPath: wait.repo).lastPathComponent
            let card = BuildCard(
                id: "\(wait.repo)#\(wait.build)", repoName: name, num: wait.build, slug: wait.slug ?? "",
                dots: [], state: "", lastActivity: wait.since, flags: [])
            board.needsYou.append(
                NeedsItem(
                    id: id, kind: .gate(GateInfo(gate: wait.gate, status: "waiting", at: wait.since)),
                    since: wait.since, card: card, repoName: name, worktree: nil, repoPath: wait.repo))
        }

        board.needsYou.sort { ($0.since, $0.id) < ($1.since, $1.id) }
        board.inProgress.sort {
            if $0.parked != $1.parked { return !$0.parked }
            return ($0.lastActivity, $1.id) > ($1.lastActivity, $0.id)
        }

        for repo in repos {
            if let error = repo.statusError {
                board.problems.append(
                    Problem(repoPath: repo.path, repoName: repo.name, error: error))
            }
            if let sweep = repo.sweep {
                let items = leftItems(repo: repo, sweep: sweep)
                board.leftBehind += items
                board.leftNotes += sweep.errors
                if !items.isEmpty { board.leftCleanup += sweep.cleanup }
                board.sweptAt = [board.sweptAt, repo.sweepAt].compactMap { $0 }.min()
            }
        }
        return board
    }

    static func cardID(_ repo: RepoSnapshot, _ row: BuildRow) -> String {
        "\(repo.path)#\(row.num)"
    }

    static func makeCard(repo: RepoSnapshot, row: BuildRow, agents: [AgentState], now: Date)
        -> BuildCard
    {
        let waiting = Set(row.waitingGates.compactMap(\.phase))
        // Phases off this build's route (marked `skipped` by the status) are hidden.
        let phases = (row.phases ?? []).filter { $0.skipped != true }.sorted { $0.n < $1.n }
        let dots: [PhaseDot] = phases.map { p in
            if waiting.contains(p.n) && p.status != "done" { return .waiting }
            switch p.status {
            case "done": return .done
            case "active": return .active
            default: return .pending
            }
        }

        var label: String?
        if let gate = row.waitingGates.first {
            label = "\(gate.title) gate"
        } else if let active = phases.first(where: { $0.status == "active" }) {
            label = active.name
        } else if !phases.isEmpty {
            if phases.allSatisfy({ $0.status == "done" }) {
                label = "Done"
            } else if let next = phases.first(where: { $0.status == "pending" }) {
                label = "\(next.name) next"
            }
        }

        let latest = agents.max { $0.lastEventAt < $1.lastEventAt }
        let agentLine = latest.map { a in
            a.isIdle
                ? "\(a.displayName) idle \(Durations.short(now.timeIntervalSince(a.lastEventAt)))"
                : "\(a.displayName) active \(Durations.ago(now.timeIntervalSince(a.lastEventAt)))"
        }

        return BuildCard(
            id: cardID(repo, row), repoName: repo.name, num: row.num, slug: row.slug,
            lane: row.lane, dots: dots, phaseLabel: label, tasks: row.tasks,
            state: row.state, startedAt: row.phases?.first(where: { $0.n == 1 })?.startedAt,
            lastActivity: max(row.lastCommitAt, latest?.lastEventAt ?? .distantPast),
            agentLine: agentLine, behind: row.behind, flags: row.flags, worktree: row.worktree,
            progress: row.progress, url: row.urls["admin"] ?? row.urls.values.sorted().first,
            staleSince: repo.statusError?.since,
            parked: row.isParked,
            agentWorking: latest.map { !$0.isIdle && now.timeIntervalSince($0.lastEventAt) < 30 * 60 } ?? false)
    }

    static func leftItems(repo: RepoSnapshot, sweep: SweepReport) -> [LeftItem] {
        var items: [LeftItem] = []
        let leaked = sweep.databases?.leaked ?? []
        if !leaked.isEmpty {
            items.append(
                LeftItem(
                    id: "\(repo.path)#dbs", repoName: repo.name,
                    title: leaked.count == 1 ? "1 leaked database" : "\(leaked.count) leaked databases",
                    details: leaked, command: nil))
        }
        if !sweep.processes.isEmpty {
            let n = sweep.processes.count
            items.append(
                LeftItem(
                    id: "\(repo.path)#procs", repoName: repo.name,
                    title: n == 1
                        ? "1 process in a deleted folder" : "\(n) processes in deleted folders",
                    details: sweep.processes.map {
                        "pid \($0.pid) · \(PathMatch.relative($0.cwd, to: repo.path)) (gone)"
                    },
                    command: "kill " + sweep.processes.map { String($0.pid) }.joined(separator: " ")))
        }
        if !sweep.routes.isEmpty {
            let n = sweep.routes.count
            items.append(
                LeftItem(
                    id: "\(repo.path)#routes", repoName: repo.name,
                    title: n == 1 ? "1 stray route" : "\(n) stray routes",
                    details: sweep.routes.map { r in
                        r.reason.map { "\(r.hostname) — \($0)" } ?? r.hostname
                    },
                    command: nil))
        }
        return items
    }
}

public enum PathMatch {
    public static func normalize(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// `path` is `root` or inside it.
    public static func contains(_ root: String, _ path: String) -> Bool {
        let r = normalize(root)
        let p = normalize(path)
        return p == r || p.hasPrefix(r + "/")
    }

    /// `path` relative to `root` when inside it, else unchanged.
    public static func relative(_ path: String, to root: String) -> String {
        let r = normalize(root)
        let p = normalize(path)
        return p.hasPrefix(r + "/") ? String(p.dropFirst(r.count + 1)) : p
    }
}
