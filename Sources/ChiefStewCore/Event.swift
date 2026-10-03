import Foundation

/// One inbox event. See docs/event-contract.md § 3.
public struct Event: Sendable, Equatable {
    /// Unique per event, set by the emitter. Copies with the same ID are handled once.
    public var id: String?
    /// Who sent it: `chiefstew-hook` (Chief Stew's Claude Code hooks), `chiefstew-emit`, or the
    /// sender's own name. Used to spot a repo re-sending what Chief Stew's hooks already send.
    public var producer: String?
    public var ts: Date
    public var kind: String
    public var repo: String
    public var worktree: String?
    public var build: String?
    public var slug: String?
    public var lane: String?
    public var phase: Int?
    public var gate: String?
    public var session: String?
    public var agent: String?
    public var notificationType: String?
    public var message: String?
    /// The app hosting the agent's session (from `chiefstew hook`): bundle ID, pid, terminal.
    public var hostApp: String?
    public var hostPid: Int?
    public var tty: String?

    public init(
        ts: Date, kind: String, repo: String, worktree: String? = nil, build: String? = nil,
        slug: String? = nil, lane: String? = nil, phase: Int? = nil, gate: String? = nil,
        session: String? = nil, agent: String? = nil, notificationType: String? = nil,
        message: String? = nil
    ) {
        self.ts = ts
        self.kind = kind
        self.repo = repo
        self.worktree = worktree
        self.build = build
        self.slug = slug
        self.lane = lane
        self.phase = phase
        self.gate = gate
        self.session = session
        self.agent = agent
        self.notificationType = notificationType
        self.message = message
    }

    public static let maxBytes = 16 * 1024
    public static let maxMessage = 200
    public static let maxID = 64
    /// Gate names are the repo's own (review, qa, sign-off, …): a short lowercase token.
    public static func isGateName(_ s: String) -> Bool {
        (1...32).contains(s.count)
            && s.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "_" }
    }

    /// Fields each known kind needs beyond `v`, `ts`, `kind` and `repo`. Unknown kinds need none.
    static let requirements: [String: [String]] = [
        "phase.started": ["build", "phase"],
        "phase.done": ["build", "phase"],
        "gate.waiting": ["build", "gate"],
        "gate.approved": ["build", "gate"],
        "build.closed": ["build"],
        "agent.needs_input": ["session"],
        "agent.stopped": ["session"],
        "agent.resumed": ["session"],
        "agent.active": ["session"],
        "agent.ended": ["session"],
    ]

    public var isAgentEvent: Bool { kind.hasPrefix("agent.") }

    /// Claude Code's Notification hook fires for more than questions. Its idle reminder (60 s
    /// after a turn ends) and auth notices aren't the agent asking anything: the Stop before the
    /// reminder already said the session is waiting. Older Claude Code sends no type, so the
    /// reminder is also recognised by its text.
    public var asksForInput: Bool {
        guard kind == "agent.needs_input" else { return false }
        switch notificationType {
        case "idle_prompt", "auth_success": return false
        case nil: return message != "Claude is waiting for your input"
        default: return true
        }
    }

    /// The event as contract JSON (§3.1), as written to the journal.
    public var json: [String: Any] {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var d: [String: Any] = ["v": 1, "ts": f.string(from: ts), "kind": kind, "repo": repo]
        let optional: [String: Any?] = [
            "id": id, "producer": producer, "worktree": worktree, "build": build, "slug": slug, "lane": lane, "phase": phase,
            "gate": gate, "session": session, "agent": agent, "notification_type": notificationType,
            "message": message, "host_app": hostApp, "host_pid": hostPid, "tty": tty,
        ]
        for case let (k, v?) in optional { d[k] = v }
        return d
    }

    /// Parse and validate one inbox file. `fallbackDate` (the file's mtime) replaces a bad `ts`.
    public static func parse(_ data: Data, fallbackDate: Date) throws -> Event {
        guard data.count <= maxBytes else { throw EventError.tooLarge(data.count) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EventError.notJSON
        }
        let v = json["v"] as? Int
        guard v == 1 else { throw EventError.wrongVersion(v) }
        func string(_ key: String) -> String? {
            guard let s = json[key] as? String, !s.isEmpty else { return nil }
            return s
        }
        guard let kind = string("kind") else { throw EventError.missing("kind") }
        guard let repo = string("repo") else { throw EventError.missing("repo") }

        var phase = json["phase"] as? Int
        if let p = phase, !(1...7).contains(p) { phase = nil }
        var gate = string("gate")?.lowercased()
        if let g = gate, !isGateName(g) { gate = nil }
        let message = string("message").map { String($0.prefix(maxMessage)) }

        var event = Event(
            ts: string("ts").flatMap(LooseDate.parse) ?? fallbackDate,
            kind: kind, repo: repo, worktree: string("worktree"), build: string("build"),
            slug: string("slug"), lane: string("lane"), phase: phase, gate: gate,
            session: string("session"), agent: string("agent"),
            notificationType: string("notification_type"), message: message)
        event.id = string("id").map { String($0.prefix(maxID)) }
        event.producer = string("producer").map { String($0.prefix(maxID)) }
        event.hostApp = string("host_app")
        event.hostPid = json["host_pid"] as? Int
        event.tty = string("tty")

        for field in requirements[kind] ?? [] {
            let present: Bool =
                switch field {
                case "build": event.build != nil
                case "phase": event.phase != nil
                case "gate": event.gate != nil
                case "session": event.session != nil
                default: true
                }
            if !present { throw EventError.missing(field) }
        }
        return event
    }
}

public enum EventError: Error, Equatable, CustomStringConvertible {
    case tooLarge(Int)
    case notJSON
    case wrongVersion(Int?)
    case missing(String)

    public var description: String {
        switch self {
        case .tooLarge(let n): "file is \(n) bytes (limit \(Event.maxBytes))"
        case .notJSON: "not a JSON object"
        case .wrongVersion(let v): "unsupported v \(v.map(String.init) ?? "(none)")"
        case .missing(let f): "missing or invalid \(f)"
        }
    }
}
