import Foundation

/// Gates known only from events (`gate.waiting` until `gate.approved` or `build.closed`). The
/// board uses them for a repo whose status can't show the gate: not registered, not read yet,
/// or failing.
public struct EventGates: Sendable, Equatable {
    public static let forgetAfter: TimeInterval = 24 * 3600

    public struct Wait: Sendable, Equatable {
        public var repo: String
        public var build: String
        public var gate: String
        public var slug: String?
        public var since: Date
    }

    public private(set) var waits: [String: Wait] = [:]

    public init() {}

    public mutating func apply(_ e: Event) {
        guard let build = e.build else { return }
        let repo = PathMatch.normalize(e.repo)
        switch e.kind {
        case "gate.waiting":
            guard let gate = e.gate else { return }
            let key = "\(repo)#\(build)#\(gate)"
            if waits[key] == nil { waits[key] = Wait(repo: repo, build: build, gate: gate, slug: e.slug, since: e.ts) }
        case "gate.approved":
            guard let gate = e.gate else { return }
            waits["\(repo)#\(build)#\(gate)"] = nil
        case "build.closed":
            waits = waits.filter { !($0.value.repo == repo && $0.value.build == build) }
        default: break
        }
    }

    public func current(now: Date) -> [Wait] {
        waits.values.filter { now.timeIntervalSince($0.since) < Self.forgetAfter }
            .sorted { ($0.since, $0.build, $0.gate) < ($1.since, $1.build, $1.gate) }
    }
}

/// Everything Chief Stew knows from events, built by applying them in order. Pure: the same
/// events give the same state, so replaying the journal at launch rebuilds it exactly.
public struct EventState: Sendable, Equatable {
    public static let rememberIDs = 2000

    public private(set) var agents: AgentTracker
    public private(set) var gates = EventGates()
    private var seen = Set<String>()
    private var seenOrder: [String] = []
    /// Repos that send agent events of their own alongside Chief Stew's hooks → when last seen.
    public private(set) var doubled: [String: Date] = [:]
    private var lastAgent: [String: LastAgent] = [:]

    private struct LastAgent: Sendable, Equatable {
        var kind: String
        var ts: Date
        var fromHook: Bool
    }

    /// Shown in Settings and by `chiefstew check` for a doubled repo.
    public static let doubledHint =
        "⚠ This repo sends its own agent events (needs input, stopped, …) as well as Chief Stew's Claude Code hooks. Remove the repo's own: Chief Stew's hooks already cover every repo."

    public init(agents: AgentTracker = AgentTracker()) {
        self.agents = agents
    }

    /// Applies one event. Returns false for a copy of an event already applied (same `id`),
    /// which changes nothing.
    @discardableResult
    public mutating func apply(_ e: Event) -> Bool {
        if let id = e.id {
            guard seen.insert(id).inserted else { return false }
            seenOrder.append(id)
            if seenOrder.count > Self.rememberIDs {
                seen.remove(seenOrder.removeFirst())
            }
        }
        noteProducer(e)
        agents.apply(e)
        gates.apply(e)
        return true
    }

    /// The same agent event from Chief Stew's hook and from somewhere else, moments apart,
    /// means the repo re-sends what the hooks already send (one producer per fact).
    private mutating func noteProducer(_ e: Event) {
        guard e.isAgentEvent, let session = e.session else { return }
        let fromHook = e.producer == "chiefstew-hook"
        if let prev = lastAgent[session], prev.kind == e.kind, prev.fromHook != fromHook,
            abs(e.ts.timeIntervalSince(prev.ts)) < 3
        {
            doubled[PathMatch.normalize(e.repo)] = e.ts
        }
        lastAgent[session] = LastAgent(kind: e.kind, ts: e.ts, fromHook: fromHook)
    }

    /// Doubled repos seen in the last day.
    public func doubledRepos(now: Date) -> [String: Date] {
        doubled.filter { now.timeIntervalSince($0.value) < 24 * 3600 }
    }

    public mutating func prune(now: Date) {
        agents.prune(now: now)
        lastAgent = lastAgent.filter { now.timeIntervalSince($0.value.ts) < 24 * 3600 }
    }
}

/// The append-only record of every event handled (`events.jsonl`, one contract JSON object per
/// line). Rotated at `maxBytes`, keeping one previous file, so at least a day is kept in practice.
public struct EventJournal: Sendable {
    public static let maxBytes = 4 * 1024 * 1024
    public static let replayWindow: TimeInterval = 24 * 3600

    public let url: URL
    public let previous: URL

    public init(paths: Paths) {
        url = paths.journal
        previous = paths.journalPrevious
    }

    public func append(_ events: [Event]) {
        guard !events.isEmpty else { return }
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.maxBytes {
            try? fm.removeItem(at: previous)
            try? fm.moveItem(at: url, to: previous)
        }
        var data = Data()
        for e in events {
            guard let line = try? JSONSerialization.data(withJSONObject: e.json, options: [.sortedKeys, .withoutEscapingSlashes])
            else { continue }
            data.append(line)
            data.append(0x0A)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// The events of the last `replayWindow`, oldest first. Unreadable lines are skipped.
    public func replay(now: Date = Date()) -> [Event] {
        var events: [Event] = []
        for file in [previous, url] {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                guard let e = try? Event.parse(Data(line.utf8), fallbackDate: .distantPast),
                    now.timeIntervalSince(e.ts) < Self.replayWindow
                else { continue }
                events.append(e)
            }
        }
        return events.enumerated().sorted { ($0.element.ts, $0.offset) < ($1.element.ts, $1.offset) }.map(\.element)
    }
}
