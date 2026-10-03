import Foundation

/// The `"workflow"` section of `.chiefstew.json`: a description of where a repo's builds and
/// their phases, gates and tasks are written down. The engine turns it into contract status
/// (docs/workflow.md). It's data: nothing in it is executed.
public struct WorkflowSpec: Sendable, Equatable {
    public enum Builds: Sendable, Equatable {
        /// Each git worktree other than the main one.
        case worktrees
        /// Local branches matching a pattern like `build/{num}-{slug}`.
        case branches(pattern: String)
        /// Folders on the main checkout matching a pattern like `docs/builds/{num}_{slug}`.
        case folders(pattern: String)
    }

    /// Where to read text: the first file that exists, optionally one markdown section of it.
    public struct Locator: Sendable, Equatable {
        public var files: [String]
        public var section: String?
    }

    public enum Pick: String, Sendable, Equatable { case firstLine = "first-line", firstQuote = "first-quote" }

    /// A single value: picked from the text, or a regex's named group (or first group).
    public struct TextRule: Sendable, Equatable {
        public var at: Locator
        public var pick: Pick?
        public var match: String?
        public var fallback: String?
    }

    public enum ListKind: Sendable, Equatable {
        case checkboxes
        /// Applied per line; named groups give fields.
        case regex(String)
    }

    public struct ListRule: Sendable, Equatable {
        public var at: Locator
        public var list: ListKind
    }

    public struct GateRule: Sendable, Equatable {
        public var at: Locator
        public var list: ListKind
        public var phase: [String: Int]
        /// Per gate name, or one template for all; relative to the build's folder.
        public var artefact: [String: String]
        public var artefactTemplate: String?
        public var approve: String?
    }

    public var builds: Builds
    /// With `branches`, builds that only exist as `origin/…` (already fetched; never fetches):
    /// nil (the default) counts those with a commit in the last 30 days, so work pushed from
    /// another machine shows up without anyone knowing about this setting; true counts all,
    /// false none.
    public var includeRemote: Bool?
    public static let recentRemoteDays = 30
    public var folder: String?
    public var state: TextRule?
    public var lane: TextRule?
    public var parked: String?
    public var closed: String?
    public var phases: ListRule?
    public var skip: (lane: String, phases: [Int])?
    public var gates: GateRule?
    public var tasks: Locator?
    /// The phases the tasks belong to: they're reported only while one of them is active.
    public var tasksPhases: [Int]?
    /// Keys this copy doesn't know: ignored, and reported by `chiefstew check`. A typo, or a key a
    /// newer Chief Stew understands, so a description written for a newer copy still works here.
    public var warnings: [Problem] = []

    public static func == (a: WorkflowSpec, b: WorkflowSpec) -> Bool {
        a.builds == b.builds && a.includeRemote == b.includeRemote && a.folder == b.folder && a.state == b.state && a.lane == b.lane
            && a.parked == b.parked && a.closed == b.closed && a.phases == b.phases
            && a.skip?.lane == b.skip?.lane && a.skip?.phases == b.skip?.phases && a.gates == b.gates
            && a.tasks == b.tasks && a.tasksPhases == b.tasksPhases
    }

    /// One problem in the description, with where it is (`workflow.phases.list`).
    public struct Problem: Error, Sendable, Equatable, CustomStringConvertible {
        public var path: String
        public var message: String
        public var description: String { "\(path): \(message)" }
    }

    /// Every problem found, not just the first.
    public struct Problems: Error, Sendable, Equatable, CustomStringConvertible {
        public var list: [Problem]
        public var description: String { list.map(\.description).joined(separator: "\n") }
    }

    /// Parses and checks the `workflow` object.
    public static func parse(_ any: Any) -> Result<WorkflowSpec, Problems> {
        var problems: [Problem] = []
        var warnings: [Problem] = []
        func fail(_ path: String, _ message: String) { problems.append(Problem(path: path, message: message)) }
        func unknown(_ path: String, _ known: Set<String>) {
            warnings.append(Problem(path: path, message: Self.unknownKey(known)))
        }
        guard let w = any as? [String: Any] else {
            return .failure(Problems(list: [Problem(path: "workflow", message: "must be an object")]))
        }
        let known: Set<String> = ["builds", "folder", "state", "lane", "parked", "closed", "phases", "gates", "tasks"]
        for key in w.keys.sorted() where !known.contains(key) {
            unknown("workflow.\(key)", known)
        }

        func regex(_ pattern: String, _ path: String) -> String? {
            do {
                _ = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
                return pattern
            } catch {
                fail(path, "not a valid regular expression")
                return nil
            }
        }
        func locator(_ o: [String: Any], _ path: String) -> Locator? {
            var files: [String] = []
            if let f = o["file"] as? String { files = [f] } else if let f = o["file"] as? [String] { files = f }
            guard !files.isEmpty, files.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("/") && !$0.contains("..") })
            else {
                fail("\(path).file", "a relative path, or a list of them, is required")
                return nil
            }
            return Locator(files: files, section: o["section"] as? String)
        }
        // Keys each rule understands. Anything else is ignored and reported by `check`: a guess
        // like "line": 1 must not look as if it did something, and a key from a newer Chief Stew
        // must not break an older one.
        let allowed: [String: Set<String>] = [
            "builds": ["from", "branch", "folder", "remote"],
            "state": ["file", "section", "pick", "match", "default"],
            "lane": ["file", "section", "pick", "match", "default"],
            "parked": ["state"], "closed": ["state"],
            "phases": ["file", "section", "list", "skip"],
            "gates": ["file", "section", "list", "phase", "artefact", "approve"],
            "tasks": ["file", "section", "count", "phase"],
        ]
        func object(_ key: String) -> [String: Any]? {
            guard let v = w[key] else { return nil }
            guard let o = v as? [String: Any] else {
                fail("workflow.\(key)", "must be an object")
                return nil
            }
            if let ok = allowed[key] {
                for k in o.keys.sorted() where !ok.contains(k) {
                    unknown("workflow.\(key).\(k)", ok)
                }
            }
            return o
        }
        func textRule(_ key: String) -> TextRule? {
            guard let o = object(key), let at = locator(o, "workflow.\(key)") else { return nil }
            var pick: Pick?
            if let p = o["pick"] as? String {
                pick = Pick(rawValue: p)
                if pick == nil { fail("workflow.\(key).pick", "use first-line or first-quote") }
            }
            let match = (o["match"] as? String).flatMap { regex($0, "workflow.\(key).match") }
            return TextRule(at: at, pick: pick, match: match, fallback: o["default"] as? String)
        }
        func listKind(_ o: [String: Any], _ path: String) -> ListKind? {
            guard let l = o["list"] as? String else {
                fail("\(path).list", "required: \"checkboxes\" or a regular expression")
                return nil
            }
            if l == "checkboxes" { return .checkboxes }
            return regex(l, "\(path).list").map(ListKind.regex)
        }
        func stateRegex(_ key: String) -> String? {
            guard let o = object(key) else { return nil }
            guard let r = o["state"] as? String else {
                fail("workflow.\(key).state", "a regular expression on the state line is required")
                return nil
            }
            return regex(r, "workflow.\(key).state")
        }

        // builds
        var builds: Builds?
        if let b = object("builds") {
            switch b["from"] as? String {
            case "worktrees": builds = .worktrees
            case "branches":
                if let p = b["branch"] as? String, p.contains("{") { builds = .branches(pattern: p) } else {
                    fail("workflow.builds.branch", "a pattern like \"build/{num}-{slug}\" is required")
                }
            case "folders":
                if let p = b["folder"] as? String, p.contains("{") { builds = .folders(pattern: p) } else {
                    fail("workflow.builds.folder", "a pattern like \"docs/builds/{num}_{slug}\" is required")
                }
            default: fail("workflow.builds.from", "use worktrees, branches or folders")
            }
        } else if w["builds"] == nil {
            fail("workflow.builds", "required")
        }
        var folder = (object("builds")?["folder"] as? String)
        if case .folders = builds { folder = nil }  // there the pattern is the folder itself

        var spec = WorkflowSpec(builds: builds ?? .worktrees)
        spec.folder = folder
        spec.includeRemote = object("builds")?["remote"] as? Bool
        spec.state = textRule("state")
        spec.lane = textRule("lane")
        spec.parked = stateRegex("parked")
        spec.closed = stateRegex("closed")
        if let o = object("phases"), let at = locator(o, "workflow.phases"),
            let list = listKind(o, "workflow.phases")
        {
            spec.phases = ListRule(at: at, list: list)
            if let s = o["skip"] as? [String: Any] {
                if let lane = s["lane"] as? String, let n = s["phases"] as? [Int] { spec.skip = (lane, n) } else {
                    fail("workflow.phases.skip", "needs {\"lane\": \"…\", \"phases\": [numbers]}")
                }
            }
        }
        if let o = object("gates"), let at = locator(o, "workflow.gates"), let list = listKind(o, "workflow.gates") {
            var rule = GateRule(at: at, list: list, phase: [:], artefact: [:], artefactTemplate: nil,
                approve: o["approve"] as? String)
            if let p = o["phase"] as? [String: Int] {
                rule.phase = Dictionary(p.map { (gateKey($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
            }
            if let a = o["artefact"] as? [String: String] {
                rule.artefact = Dictionary(a.map { (gateKey($0.key), $0.value) }, uniquingKeysWith: { a, _ in a })
            } else if let a = o["artefact"] as? String {
                rule.artefactTemplate = a
            }
            spec.gates = rule
        }
        if let o = object("tasks") {
            if o["count"] as? String != "checkboxes" { fail("workflow.tasks.count", "use \"checkboxes\"") }
            spec.tasks = locator(o, "workflow.tasks")
            if let p = o["phase"] {
                if let n = p as? Int, n > 0 { spec.tasksPhases = [n] }
                else if let list = p as? [Int], !list.isEmpty, list.allSatisfy({ $0 > 0 }) { spec.tasksPhases = list }
                else { fail("workflow.tasks.phase", "a phase number, or a list of them") }
            }
        }
        var seen = Set<String>()
        spec.warnings = warnings.filter { seen.insert($0.path).inserted }
        return problems.isEmpty ? .success(spec) : .failure(Problems(list: problems))
    }

    public init(builds: Builds) { self.builds = builds }

    static func unknownKey(_ known: Set<String>) -> String {
        "unknown key, ignored: a typo, or a key a newer Chief Stew understands (known: \(known.sorted().joined(separator: ", ")))"
    }

    /// A gate's name as a tidy token: "Design review" → "design-review".
    public static func gateKey(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespaces).lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: "-")
    }
}
