import Foundation

// `status --json` and `sweep --json`. See docs/event-contract.md § 4–5.
// Decoding is lenient: a bad optional field becomes nil, a bad row is skipped, and only a
// missing required field or the wrong `v` fails the whole report.

extension KeyedDecodingContainer {
    fileprivate func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// Decodes anything, so a bad array element can be stepped over.
private struct Skip: Decodable {
    init(from decoder: Decoder) throws {}
}

public enum ReportError: Error, Equatable {
    case wrongVersion(Int)
}

public struct StatusReport: Decodable, Sendable, Equatable {
    public var repo: String?
    public var builds: [BuildRow]
    /// When the clone last fetched from origin: how fresh rows only on origin are.
    public var fetchedAt: Date?
    /// Rows that failed to decode and were left out.
    public var skippedRows: Int

    public init(repo: String? = nil, builds: [BuildRow], skippedRows: Int = 0) {
        self.repo = repo
        self.builds = builds
        self.skippedRows = skippedRows
    }

    enum CodingKeys: String, CodingKey { case v, repo, builds, fetchedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int.self, forKey: .v)
        guard v == 1 else { throw ReportError.wrongVersion(v) }
        repo = c.lenient(String.self, .repo)
        fetchedAt = c.lenient(FlexibleDate.self, .fetchedAt)?.date
        var list = try c.nestedUnkeyedContainer(forKey: .builds)
        var rows: [BuildRow] = []
        var skipped = 0
        while !list.isAtEnd {
            if let row = try? list.decode(BuildRow.self) {
                rows.append(row)
            } else {
                _ = try list.decode(Skip.self)
                skipped += 1
            }
        }
        builds = rows
        skippedRows = skipped
    }
}

public struct BuildRow: Decodable, Sendable, Equatable {
    public var num: String
    public var slug: String
    public var branch: String
    public var state: String
    public var lastCommitAt: Date
    public var merged: Bool
    public var worktree: String?
    /// Other checkouts working on this build (e.g. an agent worktree branched from it).
    public var worktrees: [String] = []
    public var behind: Int?
    public var flags: [String]
    public var lane: String?
    public var phases: [PhaseInfo]?
    public var gates: [GateInfo]
    public var tasks: TaskCount?
    public var urls: [String: String]
    public var progress: String?
    /// Set aside on purpose. Absent: a `state` starting with "Parked" counts.
    public var parkedFlag: Bool?
    /// Who wrote the build's newest commit of its own.
    public var author: String?
    /// Whether this clone's git user wrote any of its commits; nil when that can't be told.
    public var mine: Bool?
    /// The branch exists only on origin (a teammate's, or another machine's).
    public var onlyOnOrigin: Bool?
    /// The branch's web page, when origin is a known host.
    public var branchURL: String?
    /// How long the build is meant to take, wall clock from its first phase's start.
    public var budget: Budget?

    public init(
        num: String, slug: String, branch: String = "", state: String = "",
        lastCommitAt: Date, merged: Bool = false, worktree: String? = nil, behind: Int? = nil,
        flags: [String] = [], lane: String? = nil, phases: [PhaseInfo]? = nil,
        gates: [GateInfo] = [], tasks: TaskCount? = nil, urls: [String: String] = [:],
        progress: String? = nil, parked: Bool? = nil
    ) {
        self.parkedFlag = parked
        self.num = num
        self.slug = slug
        self.branch = branch
        self.state = state
        self.lastCommitAt = lastCommitAt
        self.merged = merged
        self.worktree = worktree
        self.behind = behind
        self.flags = flags
        self.lane = lane
        self.phases = phases
        self.gates = gates
        self.tasks = tasks
        self.urls = urls
        self.progress = progress
    }

    enum CodingKeys: String, CodingKey {
        case num, slug, branch, state, lastCommitAt, merged, worktree, worktrees, behind, flags, lane,
            phases, gates, tasks, urls, progress, parked, author, mine, onlyOnOrigin, branchURL, budget
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        num = try c.decode(String.self, forKey: .num)
        slug = try c.decode(String.self, forKey: .slug)
        branch = try c.decode(String.self, forKey: .branch)
        state = try c.decode(String.self, forKey: .state)
        lastCommitAt = try c.decode(FlexibleDate.self, forKey: .lastCommitAt).date
        merged = try c.decode(Bool.self, forKey: .merged)
        worktree = c.lenient(String.self, .worktree)
        worktrees = c.lenient([String].self, .worktrees) ?? []
        behind = c.lenient(Int.self, .behind)
        flags = c.lenient([String].self, .flags) ?? []
        lane = c.lenient(String.self, .lane)
        phases = c.lenient([PhaseInfo].self, .phases)
        gates = c.lenient([GateInfo].self, .gates) ?? []
        tasks = c.lenient(TaskCount.self, .tasks)
        urls = c.lenient([String: String].self, .urls) ?? [:]
        progress = c.lenient(String.self, .progress)
        parkedFlag = c.lenient(Bool.self, .parked)
        author = c.lenient(String.self, .author)
        mine = c.lenient(Bool.self, .mine)
        onlyOnOrigin = c.lenient(Bool.self, .onlyOnOrigin)
        branchURL = c.lenient(String.self, .branchURL)
        budget = c.lenient(Budget.self, .budget).flatMap { $0.hours > 0 ? $0 : nil }
    }

    public var isParked: Bool {
        parkedFlag ?? state.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("parked")
    }


    public var waitingGates: [GateInfo] { gates.filter { $0.status == "waiting" } }
}

/// A build's time budget (contract § 4b): hours, wall clock, and the repo's name for that size.
public struct Budget: Codable, Sendable, Equatable {
    public var hours: Double
    /// e.g. `L`; shown before the clock.
    public var label: String?

    public init(hours: Double, label: String? = nil) {
        self.hours = hours
        self.label = label
    }

    /// `30 min`, `2h`, `1h 30m`.
    public var text: String {
        let minutes = Int((hours * 60).rounded())
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
}

public struct PhaseInfo: Decodable, Sendable, Equatable {
    public var n: Int
    public var name: String
    /// `done`, `active` or `pending`.
    public var status: String
    public var startedAt: Date?
    public var doneAt: Date?
    /// Not part of this build's route (e.g. a shorter lane skipping phases); hidden.
    public var skipped: Bool?

    public init(
        n: Int, name: String, status: String, startedAt: Date? = nil, doneAt: Date? = nil,
        skipped: Bool? = nil
    ) {
        self.skipped = skipped
        self.n = n
        self.name = name
        self.status = status
        self.startedAt = startedAt
        self.doneAt = doneAt
    }

    enum CodingKeys: String, CodingKey { case n, name, status, startedAt, doneAt, skipped }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        n = try c.decode(Int.self, forKey: .n)
        name = try c.decode(String.self, forKey: .name)
        status = try c.decode(String.self, forKey: .status)
        startedAt = c.lenient(FlexibleDate.self, .startedAt)?.date
        doneAt = c.lenient(FlexibleDate.self, .doneAt)?.date
        skipped = c.lenient(Bool.self, .skipped)
    }
}

public struct GateInfo: Decodable, Sendable, Equatable {
    public var gate: String
    /// `waiting` or `approved`.
    public var status: String
    public var at: Date?
    public var artefact: String?
    /// The artefact in git when it isn't on disk (the build isn't checked out): `ref:path`.
    /// Chief Stew opens a read-only copy.
    public var artefactRef: String?
    public var approve: String?
    /// The phase whose exit this gate signs off, when the status says so.
    public var phaseNumber: Int?

    public init(
        gate: String, status: String, at: Date? = nil, artefact: String? = nil,
        approve: String? = nil, phase: Int? = nil
    ) {
        self.phaseNumber = phase
        self.gate = gate
        self.status = status
        self.at = at
        self.artefact = artefact
        self.approve = approve
    }

    enum CodingKeys: String, CodingKey { case gate, status, at, artefact, artefactRef, approve, phase }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gate = try c.decode(String.self, forKey: .gate).lowercased()
        status = try c.decode(String.self, forKey: .status)
        at = c.lenient(FlexibleDate.self, .at)?.date
        artefact = c.lenient(String.self, .artefact)
        approve = c.lenient(String.self, .approve)
        artefactRef = c.lenient(String.self, .artefactRef)
        phaseNumber = c.lenient(Int.self, .phase)
    }

    /// The phase whose exit this gate signs off, when the status says.
    public var phase: Int? { phaseNumber }
    public var title: String { gate.prefix(1).uppercased() + gate.dropFirst() }
}

public struct TaskCount: Decodable, Sendable, Equatable {
    public var done: Int
    public var total: Int

    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

public struct SweepReport: Decodable, Sendable, Equatable {
    public var databases: Databases?
    public var routes: [Route]
    public var processes: [Proc]
    public var cleanup: [String]
    public var errors: [String]

    public init(
        databases: Databases? = nil, routes: [Route] = [], processes: [Proc] = [],
        cleanup: [String] = [], errors: [String] = []
    ) {
        self.databases = databases
        self.routes = routes
        self.processes = processes
        self.cleanup = cleanup
        self.errors = errors
    }

    public struct Databases: Decodable, Sendable, Equatable {
        public var checked: Bool
        public var leaked: [String]

        public init(checked: Bool, leaked: [String] = []) {
            self.checked = checked
            self.leaked = leaked
        }

        enum CodingKeys: String, CodingKey { case checked, leaked }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            checked = c.lenient(Bool.self, .checked) ?? false
            leaked = c.lenient([String].self, .leaked) ?? []
        }
    }

    public struct Route: Decodable, Sendable, Equatable {
        public var hostname: String
        public var reason: String?

        public init(hostname: String, reason: String? = nil) {
            self.hostname = hostname
            self.reason = reason
        }
    }

    public struct Proc: Decodable, Sendable, Equatable {
        public var pid: Int
        public var cwd: String

        public init(pid: Int, cwd: String) {
            self.pid = pid
            self.cwd = cwd
        }
    }

    enum CodingKeys: String, CodingKey { case v, databases, routes, processes, cleanup, errors }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let v = try c.decode(Int.self, forKey: .v)
        guard v == 1 else { throw ReportError.wrongVersion(v) }
        databases = c.lenient(Databases.self, .databases)
        routes = c.lenient([Route].self, .routes) ?? []
        processes = c.lenient([Proc].self, .processes) ?? []
        cleanup = c.lenient([String].self, .cleanup) ?? []
        errors = c.lenient([String].self, .errors) ?? []
    }
}
