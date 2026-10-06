import Foundation

/// Everything known about one registered repo: the last good status and sweep, and any error.
public struct RepoSnapshot: Sendable, Equatable {
    public var path: String
    public var status: StatusReport?
    public var statusAt: Date?
    public var statusError: RepoError?
    public var sweep: SweepReport?
    public var sweepAt: Date?
    /// The last sweep failed; any earlier sweep is still shown.
    public var sweepError: RepoError?
    /// The repo has no status command: only its agents are watched.
    public var agentsOnly = false
    /// `.chiefstew.json` has a `roadmap` (contract § 4c), read or not.
    public var roadmapConfigured = false
    public var roadmap: Roadmap?
    /// The roadmap couldn't be read: shown on its own, never in place of status.
    public var roadmapError: RepoError?

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
    /// The start was written as a day only: shown as "since 6 Oct", never as hours elapsed.
    public var startedDateOnly = false
    public var lastActivity: Date
    /// `Claude working`, `Claude idle 9 min`, from Claude Code's own session status; nil when
    /// that isn't known.
    public var agentLine: String?
    public var behind: Int?
    public var flags: [String]
    public var worktree: String?
    /// The build's own folder inside a shared checkout (a folder build): what "Open folder" opens.
    public var folder: String?
    public var progress: String?
    public var url: String?
    /// The repo's last status call failed; this is the last good data.
    public var staleSince: Date?
    /// Set aside on purpose: the Current state line starts with "Parked". Shown dimmed and last,
    /// and never in the menu-bar title.
    public var parked: Bool = false
    public var branch: String = ""
    /// The branch's web page (GitHub), when known.
    public var branchURL: String?
    /// Who wrote the build's newest commit of its own.
    public var author: String?
    /// The branch exists only on origin: what's shown is as of `fetchedAt`.
    public var onlyOnOrigin: Bool = false
    /// When the clone last fetched from origin.
    public var fetchedAt: Date?
    /// Busy sessions on this build, or in the checkout it shares: for "Go to session".
    public var workingSessions: [String] = []
    /// Claude Code says a session in this build's checkout is busy. On a parked build it means
    /// the build was picked up again before its Current state line said so.
    public var agentWorking: Bool = false
    /// The repo it's in, so the window can show it under its repo.
    public var repoPath: String = ""
    /// How long it's meant to take, wall clock from its first phase's start.
    public var budget: Budget?
    /// This clone's git user wrote some of it; nil when that can't be told (counts as yours).
    public var mine: Bool?

    /// Elapsed against the budget, for a build that has one, has started, and is neither parked
    /// nor closed (a closed build's clock has stopped, and Chief Stew doesn't know when).
    public func budgetClock(now: Date) -> (elapsed: TimeInterval, budget: TimeInterval)? {
        // A day alone can't time a budget: midnight would put it hours over.
        guard let budget, let startedAt, !startedDateOnly, !parked, !flags.contains("closed-unmerged") else { return nil }
        return (now.timeIntervalSince(startedAt), budget.hours * 3600)
    }

    /// The row's one status label, next to its name.
    public var tag: String? {
        staleSince != nil ? "stale" : parked ? (agentWorking ? "parked · agent active" : "parked") : nil
    }
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

/// Agent sessions working in a registered repo that aren't on one build: in its main checkout,
/// or in a checkout several builds share, where Chief Stew can't tell which build it's on.
public struct RepoAgents: Sendable, Equatable, Identifiable {
    public var id: String { repoPath }
    public var repoPath: String
    public var repoName: String
    /// The busy sessions (Claude Code's: only its session list says one is working), newest first.
    public var sessions: [String]

    public var line: String {
        sessions.count == 1 ? "Claude working" : "\(sessions.count) Claude sessions working"
    }
}

public struct LeftItem: Sendable, Equatable, Identifiable {
    public var id: String
    public var repoName: String
    public var title: String
    public var details: [String]
    /// A command the owner can copy; Chief Stew never runs it.
    public var command: String?
    public var repoPath: String = ""
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
    /// A registered repo's status is failing (part of `warning`).
    public var unreadable: Bool = false
    /// A registered repo hasn't been read yet.
    public var loading: Bool = false
}

public struct Board: Sendable, Equatable {
    public var needsYou: [NeedsItem] = []
    /// A teammate's build that's closed but not merged: worth knowing, not yours to act on.
    public var team: [NeedsItem] = []
    public var inProgress: [BuildCard] = []
    /// Agents working in a repo but not on one build: shown under In progress, after the builds.
    public var agentsWorking: [RepoAgents] = []
    public var leftBehind: [LeftItem] = []
    public var leftNotes: [String] = []
    /// The sweep's `cleanup` commands: shown to copy, never run.
    public var leftCleanup: [String] = []
    public var sweptAt: Date?
    public var problems: [Problem] = []
    /// Your builds running past their budget (a quiet notice each; never "needs you").
    public var overBudget: [BuildCard] = []
    public var repoNames: [String] = []
    /// Registered repos whose status hasn't been read yet (first poll still running).
    public var loading: [String] = []
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
        if parts.isEmpty, !agentsWorking.isEmpty { return agentsWorking.count == 1 ? agentsWorking[0].line : "Agents working" }
        if parts.isEmpty { return loading.isEmpty ? "Nothing in flight" : "Checking…" }
        return parts.joined(separator: " · ")
    }

    public var menu: MenuBarState {
        let unreadable = !problems.isEmpty
        let warning = !leftBehind.isEmpty || unreadable
        let loading = !loading.isEmpty
        if needsYou.count == 1 {
            return .init(
                title: needsYou[0].menuTitle, attention: true, warning: warning, busy: true,
                unreadable: unreadable, loading: loading)
        }
        if needsYou.count > 1 {
            return .init(
                title: "\(needsYou.count) need you", attention: true, warning: warning, busy: true,
                unreadable: unreadable, loading: loading)
        }
        let active = active
        guard let top = active.first else {
            return .init(
                title: nil, attention: false, warning: warning, busy: !agentsWorking.isEmpty,
                unreadable: unreadable, loading: loading)
        }
        var title = top.num
        if let label = top.phaseLabel { title += " \(label)" }
        if let t = top.tasks, t.total > 0 { title += " \(t.done)/\(t.total)" }
        if active.count > 1 { title += " +\(active.count - 1)" }
        return .init(
            title: title, attention: false, warning: warning, busy: true, unreadable: unreadable,
            loading: loading)
    }
}

// MARK: - The reducer

extension Board {
    /// Status + sweep + agent state → what the panel and menu bar show. Pure.
    /// - Parameter eventGates: gates known only from events; shown for a repo whose status
    ///   can't show them (not registered, not read yet, or failing).
    /// - Parameter claude: Claude Code's own session status; nil when it couldn't be read, and
    ///   then the board says nothing about whether agents are working.
    public static func make(
        repos: [RepoSnapshot], agents: [AgentState], eventGates: [EventGates.Wait] = [],
        claude: ClaudeSessions? = nil, now: Date
    ) -> Board {
        var board = Board()
        board.repoNames = repos.map(\.name)
        board.checkedAt = repos.compactMap(\.statusAt).min()
        board.loading = repos.filter { $0.status == nil && $0.statusError == nil }.map(\.name)

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
                // A folder build shares its checkout with the others: only its own folder is its.
                let places = same.compactMap { $0.folder ?? $0.worktree } + same.flatMap(\.worktrees)
                builds.append((repo, primary, places))
            }
        }

        // Each agent session belongs to the build whose checkout it runs in. The emitter sends
        // the checkout root, so this is an exact match (contract § 3.3), not a prefix match:
        // nested worktrees under .claude/worktrees are separate checkouts. A checkout two builds
        // report can't say which one a session is on, so it's on neither: each of those builds in
        // flight carries it, named for the repo rather than the build (no extra row, no guess).
        var sessionsByBuild: [String: [AgentState]] = [:]
        var sharedByBuild: [String: [AgentState]] = [:]
        var carried = Set<String>()
        var loose: [AgentState] = []
        for agent in agents {
            let target = PathMatch.normalize(agent.path)
            let matches = builds.filter { $0.paths.contains { PathMatch.normalize($0) == target } }
            if matches.count == 1, let b = matches.first {
                sessionsByBuild[cardID(b.repo, b.row), default: []].append(agent)
                continue
            }
            loose.append(agent)
            let ambiguous = Set(matches.count > 1 ? matches.map { cardID($0.repo, $0.row) } : [])
            for b in builds where !b.row.isParked {
                let id = cardID(b.repo, b.row)
                let shares = b.row.folder != nil && b.row.worktree.map(PathMatch.normalize) == target
                guard ambiguous.contains(id) || shares else { continue }
                sharedByBuild[id, default: []].append(agent)
                carried.insert(agent.session)
            }
        }

        var needBuilds = Set<String>()
        for (repo, row, _) in builds {
            let id = cardID(repo, row)
            let agents = sessionsByBuild[id] ?? []
            let card = makeCard(
                repo: repo, row: row, agents: agents, shared: sharedByBuild[id] ?? [], claude: claude, now: now)

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
                    let item = NeedsItem(
                        id: "\(id)#unmerged", kind: .unmerged, since: row.lastCommitAt,
                        card: card, repoName: repo.name, worktree: row.worktree)
                    // Only a build you wrote needs you to merge it; unknown authorship counts as yours.
                    if row.mine == false { board.team.append(item) } else { board.needsYou.append(item) }
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
        // Working sessions no build card carries (a branch repo's main checkout, or a folder repo
        // with nothing in flight), per registered repo. Only Claude Code's own session list can
        // say a session is working; without it, nothing is said.
        var working: [String: (repo: RepoSnapshot, agents: [AgentState])] = [:]
        for agent in loose where agent.needsInput == nil && !carried.contains(agent.session)
            && claude?.sessions[agent.session]?.status == .busy
        {
            let path = PathMatch.normalize(agent.repo)
            guard let repo = repos.first(where: { PathMatch.normalize($0.path) == path }) else { continue }
            working[repo.path, default: (repo, [])].agents.append(agent)
        }
        board.agentsWorking = working.values.map { w in
            RepoAgents(
                repoPath: w.repo.path, repoName: w.repo.name,
                sessions: w.agents.sorted { $0.lastEventAt > $1.lastEventAt }.map(\.session))
        }.sorted { ($0.repoName, $0.repoPath) < ($1.repoName, $1.repoPath) }

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

        var seenCards = Set<String>()
        board.overBudget = (board.needsYou.compactMap(\.card) + board.inProgress)
            .filter { seenCards.insert($0.id).inserted }
            .filter { card in
                guard card.mine != false, let clock = card.budgetClock(now: now) else { return false }
                return clock.elapsed > clock.budget
            }
            .sorted { $0.id < $1.id }
        board.needsYou.sort { ($0.since, $0.id) < ($1.since, $1.id) }
        board.team.sort { ($0.since, $0.id) < ($1.since, $1.id) }
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
            if let e = repo.sweepError {
                board.leftNotes.append("\(repo.name) sweep failed · \(e.message)")
            }
        }
        return board
    }

    static func cardID(_ repo: RepoSnapshot, _ row: BuildRow) -> String {
        "\(repo.path)#\(row.num)"
    }

    /// What a build is called after its number: its title, else its slug, unless the slug only
    /// repeats the number ("R07" from folder `R07` with slug `07`).
    static func displayName(_ row: BuildRow) -> String {
        if let title = row.title { return title }
        return row.slug != row.num && row.num.hasSuffix(row.slug) ? "" : row.slug
    }

    static func makeCard(
        repo: RepoSnapshot, row: BuildRow, agents: [AgentState], shared: [AgentState] = [],
        claude: ClaudeSessions?, now: Date
    ) -> BuildCard
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

        let first = row.phases?.first { $0.n == 1 }
        let latest = agents.max { $0.lastEventAt < $1.lastEventAt }
        let live = claude.map { c in agents.compactMap { c.sessions[$0.session] } } ?? []
        let busy = live.filter { $0.status == .busy }.count
        let idle = live.filter { $0.status == .idle }
        var agentLine: String?
        if busy > 0 {
            agentLine = busy == 1 ? "Claude working" : "\(busy) Claude sessions working"
        } else if live.contains(where: { $0.status == .waiting }) {
            agentLine = "Claude waiting for you"
        } else if !idle.isEmpty {
            // How long only if Chief Stew saw every one of them go idle.
            let since = idle.allSatisfy { $0.since != nil } ? idle.compactMap(\.since).max() : nil
            agentLine = "Claude idle" + (since.map { " \(Durations.short(now.timeIntervalSince($0)))" } ?? "")
        }
        // Sessions in the checkout this build shares: working in the repo, maybe not on this build.
        let sharedBusy = claude.map { c in shared.filter { c.sessions[$0.session]?.status == .busy } } ?? []
        if agentLine == nil, !sharedBusy.isEmpty {
            agentLine = sharedBusy.count == 1
                ? "Claude working in \(repo.name)" : "\(sharedBusy.count) Claude sessions working in \(repo.name)"
        }
        let ownBusy = claude.map { c in agents.filter { c.sessions[$0.session]?.status == .busy } } ?? []

        return BuildCard(
            id: cardID(repo, row), repoName: repo.name, num: row.num, slug: displayName(row),
            // None ticked reads as progress that isn't happening (a plan still being written).
            lane: row.lane, dots: dots, phaseLabel: label, tasks: row.tasks.flatMap { $0.done > 0 ? $0 : nil },
            state: row.state, startedAt: first?.startedAt, startedDateOnly: first?.startedDateOnly ?? false,
            lastActivity: max(row.lastCommitAt, row.changedAt ?? .distantPast, latest?.lastEventAt ?? .distantPast),
            agentLine: agentLine, behind: row.behind, flags: row.flags, worktree: row.worktree, folder: row.folder,
            progress: row.progress, url: row.urls["admin"] ?? row.urls.values.sorted().first,
            staleSince: repo.statusError?.since,
            parked: row.isParked,
            branch: row.branch, branchURL: row.branchURL, author: row.author,
            onlyOnOrigin: row.onlyOnOrigin == true, fetchedAt: repo.status?.fetchedAt,
            workingSessions: (ownBusy + sharedBusy).sorted { $0.lastEventAt > $1.lastEventAt }.map(\.session),
            agentWorking: busy > 0 || !sharedBusy.isEmpty,
            repoPath: repo.path, budget: row.budget, mine: row.mine)
    }

    static func leftItems(repo: RepoSnapshot, sweep: SweepReport) -> [LeftItem] {
        var items: [LeftItem] = []
        let leaked = sweep.databases?.leaked ?? []
        if !leaked.isEmpty {
            items.append(
                LeftItem(
                    id: "\(repo.path)#dbs", repoName: repo.name,
                    title: leaked.count == 1 ? "1 leaked database" : "\(leaked.count) leaked databases",
                    details: leaked, command: nil, repoPath: repo.path))
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
                    command: "kill " + sweep.processes.map { String($0.pid) }.joined(separator: " "),
                    repoPath: repo.path))
        }
        if !sweep.routes.isEmpty {
            let n = sweep.routes.count
            items.append(
                LeftItem(
                    id: "\(repo.path)#routes", repoName: repo.name,
                    title: n == 1 ? "1 stray route" : "\(n) stray routes",
                    details: sweep.routes.map { r in
                        r.reason.map { "\(r.hostname) · \($0)" } ?? r.hostname
                    },
                    command: nil, repoPath: repo.path))
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
