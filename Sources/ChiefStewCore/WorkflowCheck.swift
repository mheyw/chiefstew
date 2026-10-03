import Foundation

/// `chiefstew check` and the wizard's live result: what the engine makes of a repo's
/// `.chiefstew.json`, in words an agent (or a person) can act on.
public enum WorkflowCheck {
    public struct Result: Sendable {
        public var ok: Bool
        /// One line for the wizard: "3 builds · phases ✓ · gates 2/3 · tasks –".
        public var summary: String
        /// The full report for `chiefstew check`.
        public var text: String
    }

    public static func run(repo: String, file: String? = nil) -> Result {
        let repo = PathMatch.normalize(repo)
        let config = RepoConfig.load(repo: repo, file: file)
        var result = workflow(repo: repo, config: config, file: file)
        guard case .success(let c) = config else { return result }
        if !c.unknownKeys.isEmpty {
            let known = RepoConfig.knownKeys.sorted().joined(separator: ", ")
            result.text += "\n\n⚠ Unknown key\(c.unknownKeys.count == 1 ? "" : "s") in .chiefstew.json, ignored: \(c.unknownKeys.joined(separator: ", ")) (known: \(known))"
        }
        if !c.warnings.isEmpty {
            result.text += "\n\n" + c.warnings.map { "⚠ \($0.path): \($0.message)" }.joined(separator: "\n")
        }
        if c.roadmap != nil || c.roadmapProblem != nil {
            let r = roadmap(repo: repo, config: c)
            result.text += "\n\n" + r.text
            result.summary += " · " + r.summary
            result.ok = result.ok && r.ok
        }
        return result
    }

    static func workflow(repo: String, config: Swift.Result<RepoConfig, StatusError>, file: String?) -> Result {
        let name = URL(fileURLWithPath: repo).lastPathComponent
        switch config {
        case .failure(let e):
            return Result(ok: false, summary: "Problem in .chiefstew.json", text: "✗ \(e.description)")
        case .success(let c) where c.workflow == nil:
            let what: String
            switch c.source {
            case .file where c.status == nil: what = "No workflow or status command: only this repo's agents are shown."
            case .none: what = "No .chiefstew.json: only this repo's agents are shown. Run `chiefstew init` or the setup prompt."
            case .file: what = "This repo uses a status command: \(RepoConfig.display(c.status ?? [])). `check` only explains a workflow."
            default: what = "This repo uses \(c.source.rawValue). `check` only explains a workflow."
            }
            let agentsOnly = c.status == nil
            return Result(ok: c.source != .none, summary: agentsOnly ? "Agents only" : "Status command", text: what)
        case .success(let c):
            let (report, diagnostics, skipped) = WorkflowEngine(repo: repo, spec: c.workflow!).runExplained()
            let from = file.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ".chiefstew.json"
            var lines = ["\(name) · workflow from \(from)", ""]
            let n = report.builds.count
            if n == 0 {
                lines.append("✓ The description is valid. Nothing is in flight right now (from: \(describe(c.workflow!.builds))); new work shows up as soon as there is some.")
            } else {
                lines.append("✓ \(n) build\(n == 1 ? "" : "s") found (from: \(describe(c.workflow!.builds)))")
            }
            if !skipped.isEmpty {
                lines.append("")
                lines.append("  Considered and skipped:")
                for s in skipped.prefix(20) { lines.append("    · \(s)") }
                if skipped.count > 20 { lines.append("    · …and \(skipped.count - 20) more") }
            }
            // A field missing from one build is normal (a build early on has no gates yet), so
            // it's shown as "–". A field no build has at all gets a warning: the rule may be wrong.
            var found: [String: (yes: Int, all: Int)] = [:]
            for d in diagnostics {
                lines.append("")
                lines.append("  \(d.num) \(d.slug)   [\(d.source)]")
                for note in d.notes {
                    lines.append("    \(note.field.padding(toLength: 7, withPad: " ", startingAt: 0)) \(note.ok ? "✓" : "–") \(note.detail)")
                    var f = found[note.field] ?? (0, 0)
                    f.all += 1
                    if note.ok { f.yes += 1 }
                    found[note.field] = f
                }
            }
            let order = ["folder", "state", "lane", "phases", "gates", "tasks"]
            let never = order.filter { found[$0].map { $0.yes == 0 } ?? false }
            lines.append("")
            if n == 0 {
                lines.append("To try the rules on real work, run check with a branch in flight (or in a scratch clone).")
            } else if never.isEmpty {
                lines.append("✓ Every rule found something. Chief Stew will show this.")
            } else {
                for field in never {
                    lines.append("⚠ \(field): not found in any build. Fine if the repo doesn't record it yet; otherwise check the rule.")
                }
            }
            let parts = ["state", "phases", "gates", "tasks"].compactMap { field -> String? in
                guard let f = found[field] else { return nil }
                return "\(field) \(f.yes == f.all ? "✓" : f.yes == 0 ? "–" : "\(f.yes)/\(f.all)")"
            }
            let summary = n == 0 ? "Valid · nothing in flight right now"
                : (["\(n) build\(n == 1 ? "" : "s")"] + parts).joined(separator: " · ")
            return Result(ok: true, summary: summary, text: lines.joined(separator: "\n"))
        }
    }

    /// The roadmap part of `check`: where it was read from, every group, and everything not read
    /// or not understood, so nothing in the file goes unexplained.
    static func roadmap(repo: String, config c: RepoConfig) -> Result {
        if let problem = c.roadmapProblem {
            return Result(ok: false, summary: "roadmap ✗", text: "Roadmap\n✗ \(problem)")
        }
        guard let spec = c.roadmap else { return Result(ok: true, summary: "", text: "") }
        let roadmap: Roadmap
        switch RoadmapReader.read(repo: repo, spec: spec) {
        case .failure(let p):
            return Result(ok: false, summary: "roadmap ✗", text: "Roadmap\n✗ \(p.message)" + (p.hint.map { "\n  \($0)" } ?? ""))
        case .success(let r): roadmap = r
        }
        var lines: [String] = []
        var from = "\(roadmap.file) on \(roadmap.ref) · \(max(1, roadmap.bytes / 1024)) KB"
        if roadmap.fromOrigin {
            from += roadmap.fetchedAt.map { " · as of the last fetch, \(Durations.ago(Date().timeIntervalSince($0)))" } ?? " · as of the last fetch"
        }
        lines.append("Roadmap · \(from)")
        let rows = roadmap.rows
        var counts: [RowStatus: Int] = [:]
        for r in rows { counts[r.status, default: 0] += 1 }
        let words: [RowStatus: String] = [.done: "done", .folded: "folded", .dropped: "dropped", .active: "in progress", .next: "next", .planned: "planned"]
        let breakdown = [RowStatus.done, .active, .next, .planned, .folded, .dropped]
            .compactMap { s in counts[s].map { "\($0) \(words[s]!)" } }.joined(separator: ", ")
        let named = roadmap.groups.contains { !$0.name.isEmpty }
        if rows.isEmpty {
            lines.append("✗ No rows read. Check roadmap.columns and roadmap.group against the file (skipped tables are listed below).")
        } else {
            let groups = named ? " in \(roadmap.groups.count) group\(roadmap.groups.count == 1 ? "" : "s")" : ""
            lines.append("✓ \(rows.count) row\(rows.count == 1 ? "" : "s")\(groups): \(breakdown)")
        }
        if named {
            lines.append("")
            for g in roadmap.groups {
                let done = g.rows.filter { $0.status == .done }.count
                let toDo = g.rows.filter { [.planned, .next, .active].contains($0.status) }.count
                lines.append("  line \(g.line)  \(g.name): \(g.rows.count) row\(g.rows.count == 1 ? "" : "s") (\(done) done, \(toDo) to do)")
            }
        }
        func list(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            lines.append("")
            lines.append("  \(title):")
            for i in items.prefix(30) { lines.append("    · \(i)") }
            if items.count > 30 { lines.append("    · …and \(items.count - 30) more") }
        }
        list("Tables skipped", roadmap.skipped.map { "line \($0.line) \($0.reason)" })
        list("Status text no rule matched (shown as planned; add a rule if it means something else)",
            roadmap.unmatched.map { "line \($0.line) \($0.num ?? "–") \"\($0.text)\"" })
        list("Rows without an ID (shown, never joined to status)",
            rows.filter { $0.num == nil }.map { "line \($0.line) \($0.name.isEmpty ? "(no name)" : $0.name)" })
        list("Duplicates (the first row wins)",
            roadmap.duplicates.map { "\($0.num) on line \($0.line), first on line \($0.firstLine)" })
        let summary = rows.isEmpty ? "roadmap ✗" : "roadmap \(rows.count) rows"
        return Result(ok: !rows.isEmpty, summary: summary, text: lines.joined(separator: "\n"))
    }

    static func describe(_ b: WorkflowSpec.Builds) -> String {
        switch b {
        case .worktrees: "worktrees"
        case .branches(let p): "branches \(p)"
        case .folders(let p): "folders \(p)"
        }
    }
}

/// `chiefstew init` / the wizard's Start basic: a starter `.chiefstew.json` from what's in the
/// repo, with comments explaining how to grow it.
public enum WorkflowInit {
    public static func basic(repo: String) -> String {
        let git = GitReader(repo: PathMatch.normalize(repo))
        let main = git.mainBranch()
        let worktrees = git.worktrees().filter { $0.path != PathMatch.normalize(repo) }
        let branches = git.branches().filter { $0 != main }
        let builds: String
        let why: String
        if !worktrees.isEmpty || branches.isEmpty {
            builds = #"{ "from": "worktrees" }"#
            why = "Each git worktree (other than the main checkout) is a build."
        } else if let prefix = commonPrefix(branches) {
            builds = #"{ "from": "branches", "branch": "\#(prefix){slug}" }"#
            why = "Each \(prefix)… branch is a build."
        } else {
            builds = #"{ "from": "branches", "branch": "{slug}" }"#
            why = "Each branch other than \(main) is a build."
        }
        return """
            // Chief Stew: how this repo's work in flight is shown in the menu bar.
            // Format: https://github.com/mheyw/chiefstew/blob/main/docs/workflow.md
            // Check what Chief Stew makes of it: chiefstew check
            {
              "v": 1,
              "workflow": {
                // \(why)
                "builds": \(builds),
                // Add where this repo writes things down, for example:
                // "state":  { "file": "STATUS.md", "pick": "first-line" },
                // "phases": { "file": "PLAN.md", "section": "Phases", "list": "checkboxes" },
                // "gates":  { "file": "STATUS.md", "list": "^(?<gate>Review): (?<status>waiting|approved)" },
                // "tasks":  { "file": "PLAN.md", "section": "Tasks", "count": "checkboxes" },
              },
            }

            """
    }

    /// `feature/a`, `feature/b` → `feature/` (when most branches share one).
    static func commonPrefix(_ branches: [String]) -> String? {
        let prefixes = branches.compactMap { b -> String? in
            guard let slash = b.firstIndex(of: "/") else { return nil }
            return String(b[...slash])
        }
        guard let top = Dictionary(grouping: prefixes, by: { $0 }).max(by: { $0.value.count < $1.value.count }),
            top.value.count * 2 > branches.count
        else { return nil }
        return top.key
    }
}
