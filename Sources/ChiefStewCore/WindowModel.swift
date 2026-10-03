import Foundation

/// The window's tabs for one repo.
public enum WindowTab: String, Sendable, Hashable, CaseIterable {
    case roadmap, leftBehind

    public var title: String { self == .roadmap ? "Roadmap" : "Left behind" }
}

/// What the window shows: All repos (`repo == nil`) or one repo, and its tab.
public struct WindowSelection: Sendable, Hashable {
    public var repo: String?
    public var tab: WindowTab

    public init(repo: String? = nil, tab: WindowTab = .roadmap) {
        self.repo = repo
        self.tab = tab
    }
}

/// One repo, as the window shows it: its builds in flight, its roadmap joined with status, and
/// what its sweep left behind. Pure, from the same snapshots and `Board` as the panel, so the two
/// never disagree.
public struct RepoView: Sendable, Equatable, Identifiable {
    public enum Plan: Sendable, Equatable {
        /// `.chiefstew.json` has no `roadmap`.
        case notConfigured
        /// Configured, not read yet.
        case loading
        case problem(RepoError)
        case ready(RoadmapPlan)
    }

    public var id: String { path }
    public var path: String
    public var name: String
    /// Builds status reports, as the panel shows them: those needing you first.
    public var now: [BuildCard]
    public var plan: Plan
    /// Where the roadmap was read from, when it was.
    public var roadmap: Roadmap?
    public var left: [LeftItem]
    public var cleanup: [String]
    public var leftNotes: [String]
    public var sweptAt: Date?

    /// Builds in flight that aren't parked: the sidebar's count.
    public var activeCount: Int { now.filter { !$0.parked }.count }

    public var upNext: [Roadmap.Row] {
        if case .ready(let p) = plan { return p.upNext }
        return []
    }

    public static func make(repos: [RepoSnapshot], board: Board) -> [RepoView] {
        // Every card the board made, once: needs-you first (in its order), then in progress,
        // then teammates'.
        var seen = Set<String>()
        let cards = (board.needsYou.compactMap(\.card) + board.inProgress + board.team.compactMap(\.card))
            .filter { seen.insert($0.id).inserted }
        return repos.map { repo in
            let path = repo.path
            let left = board.leftBehind.filter { $0.repoPath == path }
            var notes = repo.sweep?.errors ?? []
            if let e = repo.sweepError { notes.append("Sweep failed · \(e.message)") }
            let plan: Plan
            if !repo.roadmapConfigured {
                plan = .notConfigured
            } else if let e = repo.roadmapError {
                plan = .problem(e)
            } else if let roadmap = repo.roadmap {
                let live = Set((repo.status?.builds ?? []).filter { !$0.merged }.map(\.num))
                plan = .ready(RoadmapPlan.join(roadmap, liveNums: live))
            } else {
                plan = .loading
            }
            return RepoView(
                path: path, name: repo.name, now: cards.filter { $0.repoPath == path }, plan: plan,
                roadmap: repo.roadmap, left: left, cleanup: left.isEmpty ? [] : repo.sweep?.cleanup ?? [],
                leftNotes: notes, sweptAt: repo.sweepAt)
        }
    }
}

extension Board {
    /// The panel's one-line Left behind summary: "2 leaked databases, 1 stray route".
    public var leftSummary: String {
        // Same kinds across repos are added up, in a fixed order.
        var counts: [(kind: String, n: Int)] = []
        for item in leftBehind {
            let kind = item.id.split(separator: "#").last.map(String.init) ?? item.title
            let n = max(1, item.details.count)
            if let i = counts.firstIndex(where: { $0.kind == kind }) { counts[i].n += n } else { counts.append((kind, n)) }
        }
        let words: [String: (String, String)] = [
            "dbs": ("leaked database", "leaked databases"),
            "procs": ("process in a deleted folder", "processes in deleted folders"),
            "routes": ("stray route", "stray routes"),
        ]
        return counts.map { c in
            let (one, many) = words[c.kind] ?? (c.kind, c.kind)
            return "\(c.n) \(c.n == 1 ? one : many)"
        }.joined(separator: ", ")
    }

    /// Where the panel's Details opens: the one repo with leftovers, or All repos for several.
    public var leftTarget: WindowSelection {
        let repos = Set(leftBehind.map(\.repoPath))
        return repos.count == 1 ? WindowSelection(repo: repos.first, tab: .leftBehind) : WindowSelection(repo: nil, tab: .leftBehind)
    }
}
