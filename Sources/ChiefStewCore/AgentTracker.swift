import Foundation

/// Per-session agent state, built from `agent.*` events alone (docs/event-contract.md § 3.3).
public struct AgentState: Codable, Sendable, Equatable {
    public var session: String
    public var repo: String
    /// Where the agent runs: the event's `worktree`, else its `repo`.
    public var path: String
    public var lastEventAt: Date
    public var lastKind: String
    public var needsInput: NeedsInput?
    /// The event's `agent` (`claude-code`, `codex`, …), if it said.
    public var agent: String?

    /// "Claude", "Codex", or "Agent".
    public var displayName: String { AgentState.displayName(agent) }

    public static func displayName(_ agent: String?) -> String {
        switch agent {
        case "claude-code", "claude": "Claude"
        case "codex": "Codex"
        case let other? where !other.isEmpty: other.prefix(1).uppercased() + other.dropFirst()
        default: "Agent"
        }
    }

    public struct NeedsInput: Codable, Sendable, Equatable {
        public var since: Date
        public var message: String?
    }

    /// The last event ended a turn; the agent is waiting (quietly) or done.
    public var isIdle: Bool { lastKind == "agent.stopped" }
}

public struct AgentTracker: Codable, Sendable, Equatable {
    public static let needsInputExpiry: TimeInterval = 8 * 3600
    public static let forgetAfter: TimeInterval = 24 * 3600

    public private(set) var sessions: [String: AgentState] = [:]

    public init() {}

    public mutating func apply(_ e: Event) {
        guard e.isAgentEvent, let session = e.session else { return }
        var s =
            sessions[session]
            ?? AgentState(
                session: session, repo: e.repo, path: e.worktree ?? e.repo,
                lastEventAt: .distantPast, lastKind: "", needsInput: nil)
        guard e.ts >= s.lastEventAt else { return }  // an older event arriving late changes nothing
        // Two emitters for one hook (user-level hooks plus a repo's own) send the same event
        // moments apart: keep the first.
        if e.kind == s.lastKind && e.ts.timeIntervalSince(s.lastEventAt) < 3 { return }
        switch e.kind {
        case "agent.ended":
            sessions[session] = nil  // the session closed: nothing is waiting any more
            return
        case "agent.needs_input": s.needsInput = .init(since: e.ts, message: e.message)
        // Any later sign of life from the session means the question was answered:
        // agent.active (a tool ran, e.g. after a permission prompt), stopped, resumed, …
        default: s.needsInput = nil
        }
        s.repo = e.repo
        s.path = e.worktree ?? e.repo
        s.lastEventAt = e.ts
        s.lastKind = e.kind
        if let agent = e.agent { s.agent = agent }
        sessions[session] = s
    }

    /// Sessions still worth showing at `now`, with stale needs-input expired.
    public func current(now: Date) -> [AgentState] {
        sessions.values
            .filter { now.timeIntervalSince($0.lastEventAt) < Self.forgetAfter }
            .map { s in
                var s = s
                if let n = s.needsInput, now.timeIntervalSince(n.since) > Self.needsInputExpiry {
                    s.needsInput = nil
                }
                return s
            }
            .sorted { $0.lastEventAt > $1.lastEventAt }
    }

    public mutating func prune(now: Date) {
        sessions = sessions.filter { now.timeIntervalSince($0.value.lastEventAt) < Self.forgetAfter }
    }
}
