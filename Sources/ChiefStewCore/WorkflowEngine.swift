import Foundation

/// Read-only git for the engine: a fixed set of commands that never write, with
/// `GIT_OPTIONAL_LOCKS=0`.
struct GitReader: Sendable {
    let repo: String

    func run(_ args: [String]) -> String? {
        guard
            let r = try? CommandRunner.runBlocking(
                "/usr/bin/git", ["-C", repo] + args, cwd: nil,
                environment: ["GIT_OPTIONAL_LOCKS": "0", "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                timeout: 10),
            r.exitCode == 0, !r.timedOut
        else { return nil }
        return String(decoding: r.stdout, as: UTF8.self)
    }

    func lines(_ args: [String]) -> [String] {
        (run(args) ?? "").split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }

    struct Worktree { var path: String; var branch: String?; var head: String }

    func worktrees() -> [Worktree] {
        (run(["worktree", "list", "--porcelain"]) ?? "").components(separatedBy: "\n\n").compactMap { block in
            var path: String?
            var branch: String?
            var head = ""
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { path = String(line.dropFirst(9)) }
                if line.hasPrefix("branch refs/heads/") { branch = String(line.dropFirst(18)) }
                if line.hasPrefix("HEAD ") { head = String(line.dropFirst(5)) }
            }
            return path.map { Worktree(path: PathMatch.normalize($0), branch: branch, head: head) }
        }
    }

    func branches() -> [String] { lines(["for-each-ref", "--format=%(refname:short)", "refs/heads"]) }

    /// `origin/…` branches already fetched, without the `origin/` prefix.
    func remoteBranches() -> [String] {
        lines(["for-each-ref", "--format=%(refname:short)", "refs/remotes/origin"])
            .filter { $0.hasPrefix("origin/") && $0 != "origin/HEAD" && $0 != "origin" }
            .map { String($0.dropFirst(7)) }
    }

    func tip(_ ref: String) -> String? {
        run(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"])?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func exists(_ ref: String, _ path: String) -> Bool { run(["cat-file", "-e", "\(ref):\(path)"]) != nil }

    /// The branch builds merge into: origin's default if known, else main, else master.
    func mainBranch() -> String {
        if let head = run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines), head.hasPrefix("origin/")
        {
            let name = String(head.dropFirst(7))
            if run(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"]) != nil { return name }
        }
        for name in ["main", "master"] where run(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"]) != nil {
            return name
        }
        return "HEAD"
    }

    func isMerged(_ ref: String, into main: String) -> Bool {
        run(["merge-base", "--is-ancestor", ref, main]) != nil
    }

    /// origin's default branch as a remote ref (`origin/main`), if this clone knows it. Fresher
    /// than the local main, which nobody pulls while working on a build branch.
    func originDefault() -> String? {
        guard
            let head = run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"])?
                .trimmingCharacters(in: .whitespacesAndNewlines), head.hasPrefix("origin/"), tip(head) != nil
        else { return nil }
        return head
    }

    /// `ref` changes files of its own, yet merging it into `target` would change nothing: its
    /// work is already there, squashed or rebased in. A branch of empty commits (just started)
    /// changes nothing either, so it doesn't count; nor does a conflict.
    func changesNothing(_ ref: String, into target: String) -> Bool {
        guard run(["diff", "--quiet", "\(target)...\(ref)"]) == nil,  // exits 1: it has changes
            let merged = run(["merge-tree", "--write-tree", target, ref])?.split(separator: "\n").first,
            let tree = run(["rev-parse", "\(target)^{tree}"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        return String(merged) == tree
    }

    /// Who wrote the build's own commits (those not on `base`): the newest author's name, and
    /// every author's email, lowercased.
    func authors(_ ref: String, since base: String) -> (latest: String?, emails: Set<String>) {
        let rows = lines(["log", "--no-merges", "-n", "500", "--format=%ae%x00%an", "\(base)..\(ref)"])
            .map { $0.components(separatedBy: "\u{0}") }
        return (rows.first.flatMap { $0.count > 1 ? $0[1] : nil }, Set(rows.map { $0[0].lowercased() }))
    }

    func userEmail() -> String? {
        run(["config", "user.email"]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The real host behind an ssh alias (`Host work` → `github.com`), from the ssh config.
    /// `ssh -G` only reads config; it doesn't connect.
    static func sshHost(_ alias: String) -> String {
        guard !alias.hasPrefix("-"),
            let r = try? CommandRunner.runBlocking(
                "/usr/bin/ssh", ["-G", alias], cwd: nil, environment: ["HOME": NSHomeDirectory()], timeout: 5),
            r.exitCode == 0
        else { return alias }
        let line = String(decoding: r.stdout, as: UTF8.self).split(separator: "\n")
            .first { $0.lowercased().hasPrefix("hostname ") }
        return line.map { String($0.dropFirst(9)).trimmingCharacters(in: .whitespaces) } ?? alias
    }

    func originURL() -> String? {
        run(["remote", "get-url", "origin"]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// When this clone last fetched (FETCH_HEAD's date). Chief Stew never fetches, so this is how
    /// fresh anything known only from origin is.
    func fetchedAt() -> Date? {
        guard let dir = run(["rev-parse", "--git-common-dir"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        let base = dir.hasPrefix("/") ? dir : (repo as NSString).appendingPathComponent(dir)
        let head = (base as NSString).appendingPathComponent("FETCH_HEAD")
        return (try? FileManager.default.attributesOfItem(atPath: head))?[.modificationDate] as? Date
    }

    func lastCommit(_ ref: String) -> (date: Date, subject: String)? {
        guard let out = run(["log", "-1", "--format=%ct%x00%s", ref]) else { return nil }
        let parts = out.trimmingCharacters(in: .newlines).components(separatedBy: "\u{0}")
        guard let t = parts.first.flatMap(Double.init) else { return nil }
        return (Date(timeIntervalSince1970: t), parts.count > 1 ? parts[1] : "")
    }

    func behind(_ ref: String, _ main: String) -> Int? {
        run(["rev-list", "--count", "\(ref)..\(main)"]).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    func show(_ ref: String, _ path: String) -> String? {
        guard let out = run(["show", "\(ref):\(path)"]), out.utf8.count <= WorkflowEngine.maxFile else { return nil }
        return out
    }

    func list(_ ref: String, _ dir: String) -> [String] {
        lines(["ls-tree", "--name-only", "\(ref):\(dir.isEmpty ? "" : dir)"])
    }
}

/// What the engine made of one build, field by field: for `chiefstew check` and the wizard.
public struct BuildDiagnostics: Sendable, Equatable {
    public struct Note: Sendable, Equatable {
        public var field: String
        public var ok: Bool
        public var detail: String
    }

    public var num: String
    public var slug: String
    public var source: String
    public var notes: [Note]
}

/// Turns a `WorkflowSpec` into contract status (§4) by reading the repo. Read-only: files
/// inside the repo and its worktrees, and `GitReader`'s commands.
public struct WorkflowEngine: Sendable {
    public static let maxFile = 256 * 1024

    public let repo: String
    public let spec: WorkflowSpec
    let git: GitReader

    public init(repo: String, spec: WorkflowSpec) {
        self.repo = PathMatch.normalize(repo)
        self.spec = spec
        self.git = GitReader(repo: self.repo)
    }

    struct Candidate {
        var num: String
        var slug: String
        var branch: String
        var ref: String
        /// The checkout on disk, if there is one.
        var worktree: String?
        /// Other checkouts on this build: worktrees on differently-named branches built on it.
        var extraWorktrees: [String] = []
    }

    public func run(now: Date = Date()) -> (report: StatusReport, diagnostics: [BuildDiagnostics]) {
        let r = runExplained(now: now)
        return (r.report, r.diagnostics)
    }

    /// Also says what was considered and skipped, and why (for `chiefstew check`).
    public func runExplained(now: Date = Date()) -> (report: StatusReport, diagnostics: [BuildDiagnostics], skipped: [String]) {
        let main = git.mainBranch()
        let upstream = git.originDefault()
        let worktrees = git.worktrees()
        let who = Who(me: git.userEmail(), origin: git.originURL())
        var skipped: [String] = []
        var rows: [BuildRow] = []
        var diagnostics: [BuildDiagnostics] = []
        for c in candidates(main: main, upstream: upstream, worktrees: worktrees, skipped: &skipped) {
            let (row, notes) = build(c, main: main, upstream: upstream, who: who, now: now)
            rows.append(row)
            diagnostics.append(BuildDiagnostics(num: c.num, slug: c.slug, source: source(c), notes: notes))
        }
        var report = StatusReport(repo: repo, builds: rows)
        if rows.contains(where: { $0.onlyOnOrigin == true }) { report.fetchedAt = git.fetchedAt() }
        return (report, diagnostics, skipped)
    }

    private func source(_ c: Candidate) -> String {
        if let wt = c.worktree { return "\(c.branch) · \(PathMatch.relative(wt, to: repo) == wt ? wt : PathMatch.relative(wt, to: repo))" }
        return "\(c.branch) · not checked out (read from git)"
    }

    // MARK: finding builds

    func candidates(main: String, upstream: String? = nil, worktrees: [GitReader.Worktree]) -> [Candidate] {
        var ignored: [String] = []
        return candidates(main: main, upstream: upstream, worktrees: worktrees, skipped: &ignored)
    }

    /// Where `ref`'s work already is, if it's merged: contained in the local main or origin's
    /// default, or merging it into the fresher of the two would change nothing (a squash merge).
    func mergedInto(_ ref: String, main: String, upstream: String?) -> String? {
        if git.isMerged(ref, into: main) { return main }
        if let upstream, git.isMerged(ref, into: upstream) { return upstream }
        let target = upstream ?? main
        return git.changesNothing(ref, into: target) ? target : nil
    }

    func candidates(
        main: String, upstream: String? = nil, worktrees: [GitReader.Worktree], skipped: inout [String]
    ) -> [Candidate] {
        let byBranch = Dictionary(
            worktrees.compactMap { w in w.branch.map { ($0, w.path) } }, uniquingKeysWith: { a, _ in a })
        switch spec.builds {
        // A branch with no commits beyond main looks exactly like a merged one to git (its tip is
        // already on main). So a worktree that exists counts as in flight (people remove them
        // when done), and a contained branch is only hidden when nothing has it checked out.
        case .worktrees:
            return worktrees.filter { $0.path != repo }.compactMap { w in
                let ref = w.branch ?? w.head
                if w.branch == main {
                    skipped.append("\(w.path): it has the main branch (\(main)) checked out")
                    return nil
                }
                return Candidate(
                    num: URL(fileURLWithPath: w.path).lastPathComponent, slug: w.branch ?? "detached",
                    branch: w.branch ?? "(detached \(w.head.prefix(8)))", ref: ref, worktree: w.path)
            }
        case .branches(let pattern):
            guard let re = Self.templateRegex(pattern) else { return [] }
            var out: [Candidate] = []
            for branch in git.branches() {
                if branch == main {
                    skipped.append("\(branch): the main branch")
                    continue
                }
                guard let g = Self.groups(re, branch) else {
                    skipped.append("\(branch): doesn't match \(pattern)")
                    continue
                }
                if byBranch[branch] == nil, let into = mergedInto(branch, main: main, upstream: upstream) {
                    skipped.append("\(branch): already merged into \(into)")
                    continue
                }
                out.append(
                    Candidate(
                        num: g["num"] ?? g["slug"] ?? branch, slug: g["slug"] ?? branch, branch: branch, ref: branch,
                        worktree: byBranch[branch]))
            }
            // Builds that only exist on origin (another machine, a teammate). Never fetched. By
            // default only recently active ones, so old abandoned branches don't pile up.
            if spec.includeRemote != false {
                let local = Set(git.branches())
                for branch in git.remoteBranches() where !local.contains(branch) && branch != main {
                    guard let g = Self.groups(re, branch) else { continue }
                    if let into = mergedInto("origin/\(branch)", main: main, upstream: upstream) {
                        skipped.append("origin/\(branch): already merged into \(into)")
                        continue
                    }
                    if spec.includeRemote == nil, let last = git.lastCommit("origin/\(branch)")?.date {
                        let days = Int(Date().timeIntervalSince(last) / 86400)
                        if days > WorkflowSpec.recentRemoteDays {
                            skipped.append("origin/\(branch): only on origin, no commits for \(days) days (\"remote\": true includes it)")
                            continue
                        }
                    }
                    out.append(
                        Candidate(
                            num: g["num"] ?? g["slug"] ?? branch, slug: g["slug"] ?? branch, branch: branch,
                            ref: "origin/\(branch)", worktree: nil))
                }
            }
            attachOtherWorktrees(&out, main: main, worktrees: worktrees)
            return out.sorted { $0.num < $1.num }
        case .folders(let pattern):
            let dir = (pattern as NSString).deletingLastPathComponent
            guard let re = Self.templateRegex((pattern as NSString).lastPathComponent) else { return [] }
            let names = (try? FileManager.default.contentsOfDirectory(atPath: (repo as NSString).appendingPathComponent(dir))) ?? []
            return names.sorted().compactMap { name in
                guard let g = Self.groups(re, name) else { return nil }
                return Candidate(
                    num: g["num"] ?? name, slug: g["slug"] ?? name, branch: main, ref: main, worktree: repo)
            }
        }
    }

    /// Worktrees on branches that don't match the pattern (an agent's worktree branched from a
    /// build, say) belong to the build whose tip they're built on: agents there count for it.
    func attachOtherWorktrees(_ builds: inout [Candidate], main: String, worktrees: [GitReader.Worktree]) {
        let claimed = Set(builds.compactMap(\.worktree))
        let mainTip = git.tip(main)
        let tips = builds.map { git.tip($0.ref) }
        for w in worktrees where w.path != repo && !claimed.contains(w.path) && w.branch != main {
            for i in builds.indices {
                guard let tip = tips[i], tip != mainTip, !w.head.isEmpty else { continue }
                if tip == w.head || git.isMerged(tip, into: w.head) {
                    builds[i].extraWorktrees.append(w.path)
                    break
                }
            }
        }
    }

    // MARK: one build

    /// Per run: this clone's git identity and origin URL.
    struct Who {
        var me: String?
        var origin: String?
    }

    func build(
        _ c: Candidate, main: String, upstream: String? = nil, who: Who = Who(), now: Date
    ) -> (BuildRow, [BuildDiagnostics.Note]) {
        var notes: [BuildDiagnostics.Note] = []
        func note(_ field: String, _ ok: Bool, _ detail: String) {
            notes.append(.init(field: field, ok: ok, detail: detail))
        }

        // The build's folder (where its files are), relative to its checkout.
        var base = ""
        if case .folders(let pattern) = spec.builds {
            base = (pattern as NSString).deletingLastPathComponent
            base = (base as NSString).appendingPathComponent(
                Self.fill((pattern as NSString).lastPathComponent, c, gate: nil))
            // The folder name itself was matched; rebuild it from the real listing instead.
            base = folderFor(c, pattern: pattern) ?? base
        } else if let folder = spec.folder {
            if let f = resolveFolder(Self.fill(folder, c, gate: nil), c) {
                base = f
                note("folder", true, f)
            } else {
                note("folder", false, "no folder matches \(Self.fill(folder, c, gate: nil))")
            }
        }

        let last = git.lastCommit(c.ref)
        var row = BuildRow(
            num: c.num, slug: c.slug, branch: c.branch, state: "", lastCommitAt: last?.date ?? now,
            merged: false, worktree: c.worktree, behind: git.behind(c.ref, upstream ?? main))
        row.worktrees = c.extraWorktrees
        if c.ref != main {
            let authors = git.authors(c.ref, since: upstream ?? main)
            row.author = authors.latest
            // Yours if you wrote any of its commits; unknown without a git identity.
            if let me = who.me, !authors.emails.isEmpty { row.mine = authors.emails.contains(me) }
        }
        if c.ref.hasPrefix("origin/") { row.onlyOnOrigin = true }
        row.branchURL = who.origin.flatMap { Self.branchURL(origin: $0, branch: c.branch, resolve: GitReader.sshHost) }
        if !c.extraWorktrees.isEmpty {
            note("checkouts", true, "also worked on in " + c.extraWorktrees.map { PathMatch.relative($0, to: repo) }.joined(separator: ", "))
        }

        // state
        if let rule = spec.state {
            let (text, file, why, path) = read(rule.at, base: base, c)
            if let text, let value = Self.extract(text, pick: rule.pick, match: rule.match, group: "state") {
                row.state = Self.plain(value)
                note("state", true, "\(file ?? "") → \"\(String(row.state.prefix(70)))\"")
                if let path, let wt = c.worktree { row.progress = (wt as NSString).appendingPathComponent(path) }
            } else {
                row.state = Self.plain(last?.subject ?? "")
                note("state", false, (why ?? "\(file ?? "file") matched nothing") + "; using the last commit subject")
            }
        } else {
            row.state = Self.plain(last?.subject ?? "")
        }

        // lane, parked, closed. The default picks the route but isn't reported: it's an
        // assumption, not something the repo says.
        var route: String?
        if let rule = spec.lane {
            let (text, file, why, _) = read(rule.at, base: base, c)
            let value = text.flatMap { Self.extract($0, pick: rule.pick, match: rule.match, group: "lane") }
            row.lane = value
            route = value ?? rule.fallback
            note("lane", value != nil || rule.fallback != nil, value.map { "\(file ?? "") → \($0)" } ?? (why ?? "no match; default \(rule.fallback ?? "none")"))
        }
        if let re = spec.parked { row.parkedFlag = Self.matches(re, row.state) }
        if let re = spec.closed, Self.matches(re, row.state) { row.flags.append("closed-unmerged") }

        // phases
        if let rule = spec.phases {
            let (text, file, why, _) = read(rule.at, base: base, c)
            if let text {
                var phases = Self.phases(text, rule.list)
                if let skip = spec.skip {
                    for i in phases.indices {
                        phases[i].skipped = route == skip.lane && skip.phases.contains(phases[i].n)
                    }
                }
                row.phases = phases.isEmpty ? nil : phases
                note("phases", !phases.isEmpty, phases.isEmpty ? "\(file ?? "") has no lines matching the list rule"
                    : "\(file ?? "") → " + phases.map { "\($0.name) \(Self.mark($0.status))" }.joined(separator: " "))
            } else {
                note("phases", false, why ?? "not found")
            }
        }

        // gates
        if let rule = spec.gates {
            let (text, file, why, _) = read(rule.at, base: base, c)
            if let text {
                row.gates = Self.records(text, rule.list).compactMap { r in gate(r, rule, base: base, c) }
                note("gates", true, row.gates.isEmpty ? "\(file ?? "") → none open"
                    : "\(file ?? "") → " + row.gates.map { "\($0.gate) \($0.status)" }.joined(separator: ", "))
            } else {
                note("gates", false, why ?? "not found")
            }
        }

        // tasks
        if let at = spec.tasks {
            let (text, file, why, _) = read(at, base: base, c)
            if let text {
                let boxes = Self.checkboxes(text)
                row.tasks = boxes.isEmpty ? nil : TaskCount(done: boxes.filter(\.done).count, total: boxes.count)
                note("tasks", !boxes.isEmpty, boxes.isEmpty ? "\(file ?? "") has no checkboxes" : "\(file ?? "") → \(row.tasks!.done)/\(row.tasks!.total)")
            } else {
                note("tasks", false, why ?? "not found")
            }
        }
        return (row, notes)
    }

    private func gate(_ r: [String: String], _ rule: WorkflowSpec.GateRule, base: String, _ c: Candidate) -> GateInfo? {
        guard let name = (r["gate"] ?? r["name"]).map(WorkflowSpec.gateKey), !name.isEmpty else { return nil }
        let raw = (r["status"] ?? (r["done"].map { Self.isDone($0) ? "approved" : "waiting" } ?? "waiting")).lowercased()
        let status = raw.contains("wait") || raw.contains("open") || raw.contains("pending") ? "waiting"
            : raw.contains("approv") || raw.contains("pass") || raw.contains("done") ? "approved" : raw
        var info = GateInfo(
            gate: name, status: status,
            at: r["at"].flatMap { LooseDate.parse($0.replacingOccurrences(of: "since ", with: "")) },
            phase: rule.phase[name])
        if status == "waiting" {
            if let a = rule.artefact[name] ?? rule.artefactTemplate.map({ Self.fill($0, c, gate: name) }) {
                let rel = (base as NSString).appendingPathComponent(a)
                if let wt = c.worktree, FileManager.default.fileExists(atPath: (wt as NSString).appendingPathComponent(rel)) {
                    info.artefact = (wt as NSString).appendingPathComponent(rel)
                } else if git.exists(c.ref, rel) {
                    // Not checked out: Chief Stew opens a read-only copy from git.
                    info.artefactRef = "\(c.ref):\(rel)"
                }
            }
            info.approve = rule.approve.map { Self.fill($0, c, gate: name) }
        }
        return info
    }

    // MARK: reading

    /// Text at a locator for a build: (text, the file used with its section, why not, the file
    /// used). The second is for messages; the last is a real path relative to the checkout.
    func read(_ at: WorkflowSpec.Locator, base: String, _ c: Candidate) -> (String?, String?, String?, String?) {
        for file in at.files {
            let rel = (base as NSString).appendingPathComponent(Self.fill(file, c, gate: nil))
            guard let text = readFile(rel, c) else { continue }
            guard let section = at.section else { return (text, rel, nil, rel) }
            if let body = Self.section(text, section) { return (body, "\(rel) § \(section)", nil, rel) }
            return (nil, rel, "\(rel) has no \"\(section)\" section", rel)
        }
        let tried = at.files.map { (base as NSString).appendingPathComponent(Self.fill($0, c, gate: nil)) }
        return (nil, nil, "not found: \(tried.joined(separator: ", "))", nil)
    }

    func readFile(_ rel: String, _ c: Candidate) -> String? {
        if let wt = c.worktree {
            let path = (wt as NSString).appendingPathComponent(rel)
            let real = (path as NSString).resolvingSymlinksInPath
            guard PathMatch.contains(wt, real) || PathMatch.contains(repo, real),
                let attrs = try? FileManager.default.attributesOfItem(atPath: real),
                attrs[.type] as? FileAttributeType == .typeRegular,
                (attrs[.size] as? Int ?? 0) <= Self.maxFile
            else { return nil }
            return try? String(contentsOfFile: real, encoding: .utf8)
        }
        return git.show(c.ref, rel)
    }

    /// Resolves a folder template whose last part may contain `*` (e.g. `{num}_*`).
    func resolveFolder(_ template: String, _ c: Candidate) -> String? {
        let parent = (template as NSString).deletingLastPathComponent
        let last = (template as NSString).lastPathComponent
        guard last.contains("*") else { return readable(template, c) ? template : nil }
        let regex = "^" + NSRegularExpression.escapedPattern(for: last).replacingOccurrences(of: "\\*", with: ".*") + "$"
        let names: [String]
        if let wt = c.worktree {
            names = (try? FileManager.default.contentsOfDirectory(atPath: (wt as NSString).appendingPathComponent(parent))) ?? []
        } else {
            names = git.list(c.ref, parent)
        }
        return names.sorted().first { Self.matches(regex, $0) }.map { (parent as NSString).appendingPathComponent($0) }
    }

    private func folderFor(_ c: Candidate, pattern: String) -> String? {
        let dir = (pattern as NSString).deletingLastPathComponent
        guard let re = Self.templateRegex((pattern as NSString).lastPathComponent) else { return nil }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: (repo as NSString).appendingPathComponent(dir))) ?? []
        return names.first { name in
            guard let g = Self.groups(re, name) else { return false }
            return (g["num"] ?? name) == c.num && (g["slug"] ?? name) == c.slug
        }.map { (dir as NSString).appendingPathComponent($0) }
    }

    private func readable(_ rel: String, _ c: Candidate) -> Bool {
        if let wt = c.worktree {
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: (wt as NSString).appendingPathComponent(rel), isDirectory: &isDir)
        }
        return git.run(["cat-file", "-e", "\(c.ref):\(rel)"]) != nil
    }

    // MARK: pure helpers (tested directly)

    /// The branch's page on GitHub, from origin's URL (https, ssh, or scp-style `git@host:o/r`).
    /// `resolve` maps an ssh host alias to its real host. Nil for other hosts.
    static func branchURL(origin: String, branch: String, resolve: (String) -> String = { $0 }) -> String? {
        var host: String
        var path: String
        if let url = URL(string: origin), let h = url.host, ["https", "http", "ssh"].contains(url.scheme ?? "") {
            host = h
            path = url.path
        } else if let at = origin.firstIndex(of: "@"), let colon = origin[at...].firstIndex(of: ":") {
            host = String(origin[origin.index(after: at)..<colon])
            path = String(origin[origin.index(after: colon)...])
        } else {
            return nil
        }
        if host != "github.com" { host = resolve(host) }
        path = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.hasSuffix(".git") { path = String(path.dropLast(4)) }
        guard host == "github.com", path.split(separator: "/").count == 2,
            let b = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else { return nil }
        return "https://github.com/\(path)/tree/\(b)"
    }

    /// `build/{num}-{slug}` → a regex with named groups.
    static func templateRegex(_ template: String) -> NSRegularExpression? {
        var out = "^"
        var rest = Substring(template)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            out += NSRegularExpression.escapedPattern(for: String(rest[..<open])).replacingOccurrences(of: "\\*", with: ".*")
            let name = rest[rest.index(after: open)..<close]
            out += name == "num" ? "(?<num>[^/]+?)" : name == "slug" ? "(?<slug>.+)" : ".+?"
            rest = rest[rest.index(after: close)...]
        }
        out += NSRegularExpression.escapedPattern(for: String(rest)).replacingOccurrences(of: "\\*", with: ".*") + "$"
        return try? NSRegularExpression(pattern: out)
    }

    static func groups(_ re: NSRegularExpression, _ s: String) -> [String: String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var out: [String: String] = [:]
        for name in ["num", "slug"] {
            let r = m.range(withName: name)
            if r.location != NSNotFound { out[name] = ns.substring(with: r) }
        }
        return out
    }

    static func fill(_ template: String, _ c: Candidate, gate: String?) -> String {
        var s = template.replacingOccurrences(of: "{num}", with: c.num)
            .replacingOccurrences(of: "{slug}", with: c.slug)
            .replacingOccurrences(of: "{branch}", with: c.branch)
        if let gate { s = s.replacingOccurrences(of: "{gate}", with: gate) }
        return s
    }

    static func matches(_ pattern: String, _ s: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]))?
            .firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// The body under a markdown heading named `heading`, up to the next heading of the same
    /// or a higher level.
    public static func section(_ text: String, _ heading: String) -> String? {
        let lines = text.components(separatedBy: "\n")
        let want = heading.lowercased().trimmingCharacters(in: .whitespaces)
        func level(_ l: String) -> Int? {
            let hashes = l.prefix { $0 == "#" }.count
            return hashes > 0 && hashes <= 6 && l.dropFirst(hashes).first == " " ? hashes : nil
        }
        guard let start = lines.firstIndex(where: { l in
            level(l) != nil && l.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix(want)
        }), let lvl = level(lines[start]) else { return nil }
        var body: [String] = []
        for l in lines[(start + 1)...] {
            if let n = level(l), n <= lvl { break }
            body.append(l)
        }
        return body.joined(separator: "\n")
    }

    static func extract(_ text: String, pick: WorkflowSpec.Pick?, match: String?, group: String) -> String? {
        if let match, let re = try? NSRegularExpression(pattern: match, options: [.anchorsMatchLines]) {
            let ns = text as NSString
            guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
            let named = m.range(withName: group)
            if named.location != NSNotFound { return ns.substring(with: named) }
            if m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound { return ns.substring(with: m.range(at: 1)) }
            return ns.substring(with: m.range)
        }
        let lines = text.components(separatedBy: "\n")
        switch pick ?? .firstLine {
        case .firstQuote:
            var quote: [String] = []
            for l in lines {
                if l.hasPrefix(">") { quote.append(String(l.dropFirst()).trimmingCharacters(in: .whitespaces)) }
                else if !quote.isEmpty { break }
            }
            return quote.isEmpty ? nil : quote.joined(separator: " ")
        case .firstLine:
            return lines.map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("<!--") }
        }
    }

    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "`", with: "")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func checkboxes(_ text: String) -> [(done: Bool, text: String)] {
        text.components(separatedBy: "\n").compactMap { line in
            let l = line.trimmingCharacters(in: .whitespaces)
            for (prefix, done) in [("- [ ] ", false), ("- [x] ", true), ("- [X] ", true), ("* [ ] ", false), ("* [x] ", true)]
            where l.hasPrefix(prefix) {
                return (done, String(l.dropFirst(prefix.count)))
            }
            return nil
        }
    }

    static func records(_ text: String, _ kind: WorkflowSpec.ListKind) -> [[String: String]] {
        switch kind {
        case .checkboxes:
            return checkboxes(text).map { ["done": $0.done ? "x" : " ", "name": $0.text, "gate": $0.text] }
        case .regex(let pattern):
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
            let names = groupNames(pattern)
            return text.components(separatedBy: "\n").compactMap { line in
                let ns = line as NSString
                guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
                var r: [String: String] = [:]
                for n in names {
                    let range = m.range(withName: n)
                    if range.location != NSNotFound { r[n] = ns.substring(with: range) }
                }
                return r
            }
        }
    }

    static func groupNames(_ pattern: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "\\(\\?<([A-Za-z][A-Za-z0-9]*)>") else { return [] }
        let ns = pattern as NSString
        return re.matches(in: pattern, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range(at: 1)) }
    }

    static func isDone(_ s: String) -> Bool { ["x", "X", "true", "done", "yes"].contains(s.trimmingCharacters(in: .whitespaces)) }

    static func phases(_ text: String, _ kind: WorkflowSpec.ListKind) -> [PhaseInfo] {
        let rows = records(text, kind)
        let tracksStart: Bool = {
            if case .regex(let p) = kind { return groupNames(p).contains("started") }
            return false
        }()
        var firstOpenSeen = false
        return rows.enumerated().map { i, r in
            let done = r["done"].map(isDone) ?? false
            let started = r["started"].flatMap(LooseDate.parse)
            var status = done ? "done" : "pending"
            if !done {
                if tracksStart {
                    if started != nil { status = "active" }
                } else if !firstOpenSeen {
                    status = "active"
                }
                firstOpenSeen = true
            }
            return PhaseInfo(
                n: r["n"].flatMap(Int.init) ?? i + 1,
                name: (r["name"] ?? "Phase \(i + 1)").trimmingCharacters(in: .whitespaces),
                status: status, startedAt: started, doneAt: r["doneAt"].flatMap(LooseDate.parse))
        }
    }

    static func mark(_ status: String) -> String { status == "done" ? "✓" : status == "active" ? "◐" : "○" }
}
