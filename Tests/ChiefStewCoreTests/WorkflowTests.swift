@testable import ChiefStewCore
import Foundation
import Testing

// The workflow engine against a real git repo: feature branches (one checked out in a worktree,
// one only in git, one merged), JSON5 config, and the explanations `chiefstew check` gives.

private func run(_ dir: URL, _ args: String...) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", dir.path] + args
    p.environment = [
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
        "GIT_COMMITTER_EMAIL": "t@t", "HOME": NSTemporaryDirectory(),
    ]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
}

private func write(_ dir: URL, _ path: String, _ text: String) throws {
    let url = dir.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

private let plan = """
    # Plan

    ## Phases
    - [x] Design
    - [ ] Build
    - [ ] Ship

    ## Tasks
    - [x] one
    - [x] two
    - [ ] three
    """

/// main; feature/a (worktree, review waiting); feature/c (git only, parked); feature/b (merged).
private func sampleRepo() throws -> (repo: URL, worktree: URL) {
    let repo = try tempDir().appendingPathComponent("app")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try run(repo, "init", "-q", "-b", "main")
    try write(repo, "README.md", "app")
    try run(repo, "add", ".")
    try run(repo, "commit", "-q", "-m", "init")

    try run(repo, "checkout", "-q", "-b", "feature/b")
    try run(repo, "commit", "-q", "--allow-empty", "-m", "b")
    try run(repo, "checkout", "-q", "main")
    try run(repo, "merge", "-q", "feature/b")

    try run(repo, "checkout", "-q", "-b", "feature/c")
    try write(repo, "docs/features/c/STATUS.md", "Parked until Q4\n")
    try write(repo, "docs/features/c/PLAN.md", plan)
    try run(repo, "add", ".")
    try run(repo, "commit", "-q", "-m", "c")
    try run(repo, "checkout", "-q", "main")

    let wt = repo.deletingLastPathComponent().appendingPathComponent("app-a")
    try run(repo, "worktree", "add", "-q", "-b", "feature/a", wt.path)
    try write(wt, "docs/features/a/STATUS.md", "In review\nReview: waiting since 2026-09-30 13:50\n")
    try write(wt, "docs/features/a/PLAN.md", plan)
    try write(wt, "docs/features/a/PR.md", "the PR")
    return (repo, wt)
}

private let typical = """
    // feature branches, as in docs/workflow.md
    {
      v: 1,
      workflow: {
        builds: { from: "branches", branch: "feature/{slug}", folder: "docs/features/{slug}" },
        state:  { file: "STATUS.md", pick: "first-line" },
        phases: { file: "PLAN.md", section: "Phases", list: "checkboxes" },
        gates:  { file: "STATUS.md", list: "^(?<gate>Review): (?<status>waiting|approved)(?: since (?<at>.+))?$",
                  artefact: "PR.md", approve: "gh pr ready {branch}" },
        tasks:  { file: "PLAN.md", section: "Tasks", count: "checkboxes" },
        parked: { state: "^Parked" },
      },
    }
    """

@Test func engineReadsBranchesWorktreesAndGit() throws {
    let (repo, wt) = try sampleRepo()
    try write(repo, ".chiefstew.json", typical)
    let config = try RepoConfig.load(repo: repo.path).get()
    #expect(config.source == .workflow)

    let (report, diagnostics) = WorkflowEngine(repo: repo.path, spec: config.workflow!).run()
    #expect(report.builds.map(\.slug) == ["a", "c"])  // feature/b is merged, so it's gone

    let a = report.builds[0]
    #expect(a.worktree == PathMatch.normalize(wt.path))
    #expect(a.state == "In review")
    #expect(a.phases?.map(\.status) == ["done", "active", "pending"])
    #expect(a.tasks == TaskCount(done: 2, total: 3))
    let gate = try #require(a.gates.first)
    #expect(gate.gate == "review" && gate.status == "waiting")
    #expect(gate.at != nil)
    #expect(gate.artefact?.hasSuffix("docs/features/a/PR.md") == true)
    #expect(gate.approve == "gh pr ready feature/a")
    #expect(a.isParked == false)

    let c = report.builds[1]
    #expect(c.worktree == nil)  // not checked out: read from git
    #expect(c.state == "Parked until Q4")
    #expect(c.isParked)
    #expect(c.tasks == TaskCount(done: 2, total: 3))
    #expect(diagnostics[1].notes.contains { $0.field == "gates" && $0.ok })  // file found, no gates

    // And the board puts the waiting gate under Needs you.
    let board = Board.make(repos: [RepoSnapshot(path: repo.path, status: report)], agents: [], now: Date())
    #expect(board.needsYou.first?.menuTitle == "a Review gate")
}

@Test func worktreesModeNeedsNoConfigToSpeakOf() throws {
    let (repo, _) = try sampleRepo()
    let spec = try WorkflowSpec.parse(["builds": ["from": "worktrees"]]).get()
    let report = WorkflowEngine(repo: repo.path, spec: spec).run().report
    #expect(report.builds.map(\.num) == ["app-a"])
    #expect(report.builds[0].slug == "feature/a")
}

@Test func foldersMode() throws {
    let (repo, _) = try sampleRepo()
    try write(repo, "work/012_login/STATUS.md", "Designing")
    try write(repo, "work/013_billing/STATUS.md", "Building")
    let spec = try WorkflowSpec.parse([
        "builds": ["from": "folders", "folder": "work/{num}_{slug}"],
        "state": ["file": "STATUS.md"],
    ]).get()
    let rows = WorkflowEngine(repo: repo.path, spec: spec).run().report.builds
    #expect(rows.map(\.num) == ["012", "013"])
    #expect(rows.map(\.state) == ["Designing", "Building"])
}

@Test func checkExplainsWhatItFound() throws {
    let (repo, _) = try sampleRepo()
    try write(repo, ".chiefstew.json", typical)
    let r = WorkflowCheck.run(repo: repo.path)
    #expect(r.ok)
    #expect(r.summary == "2 builds · state ✓ · phases ✓ · gates ✓ · tasks ✓")
    #expect(r.text.contains("✓ 2 builds found"))
}

@Test func specProblemsAreAllReportedWithPaths() {
    guard case .failure(let p) = WorkflowSpec.parse([
        "builds": ["from": "branches"],
        "phases": ["file": "PLAN.md", "list": "([unclosed"],
        "colour": "blue",
        "state": ["file": "STATUS.md", "line": 1],
    ]) else {
        Issue.record("expected problems")
        return
    }
    let paths = p.list.map(\.path)
    #expect(paths == ["workflow.builds.branch", "workflow.phases.list"])
}

/// An unknown key is a warning, not an error: a typo is still reported (by `check`), and a key a
/// newer Chief Stew added doesn't break an older copy, which just doesn't apply it.
@Test func unknownKeysAreIgnoredAndReported() throws {
    let repo = try tempDir()
    let fm = FileManager.default
    fm.createFile(atPath: repo.appendingPathComponent(".chiefstew.json").path, contents: Data("""
        { v: 1, workflow: { builds: { from: "worktrees", someday: true }, colour: "blue",
                            state: { file: "STATUS.md", line: 1 } } }
        """.utf8))
    let c = try RepoConfig.load(repo: repo.path).get()
    #expect(c.workflow?.builds == .worktrees)
    #expect(c.warnings.map(\.path) == ["workflow.colour", "workflow.builds.someday", "workflow.state.line"])
    #expect(c.warnings[0].message.hasPrefix("unknown key, ignored: a typo, or a key a newer Chief Stew understands"))
    let check = WorkflowCheck.run(repo: repo.path)
    #expect(check.ok)
    #expect(check.text.contains("⚠ workflow.state.line: unknown key, ignored"))
}

@Test func workflowAndStatusTogetherIsAnError() throws {
    let dir = try tempDir()
    try write(dir, ".chiefstew.json", #"{ v: 1, status: ["x"], workflow: { builds: { from: "worktrees" } } }"#)
    guard case .failure(.badConfig) = RepoConfig.load(repo: dir.path) else {
        Issue.record("expected badConfig")
        return
    }
}

@Test func initPicksTheBranchPrefixOrWorktrees() throws {
    let (repo, _) = try sampleRepo()
    #expect(WorkflowInit.basic(repo: repo.path).contains(#""from": "worktrees""#))  // it has one
    #expect(WorkflowInit.commonPrefix(["feature/a", "feature/b", "fix/c"]) == "feature/")
    #expect(WorkflowInit.commonPrefix(["a", "b"]) == nil)
    // The starter file is valid JSON5 the engine accepts.
    try write(repo, ".chiefstew.json", WorkflowInit.basic(repo: repo.path))
    #expect(try RepoConfig.load(repo: repo.path).get().source == .workflow)
}

@Test func markdownHelpers() {
    let md = "# T\n\n## Current state\n\n> **Phase 2** —\n> step 3\n\n## Next\nx"
    #expect(WorkflowEngine.section(md, "current state")?.contains("Phase 2") == true)
    #expect(WorkflowEngine.section(md, "Current state")?.contains("x") == false)
    #expect(WorkflowEngine.extract(WorkflowEngine.section(md, "Current state")!, pick: .firstQuote, match: nil, group: "state")
        .map(WorkflowEngine.plain) == "Phase 2 — step 3")
    #expect(WorkflowEngine.templateRegex("build/{num}-{slug}").flatMap { WorkflowEngine.groups($0, "build/173-data-x") }
        == ["num": "173", "slug": "data-x"])
}

/// Every example in docs/workflow.md must be a valid description (the docs can't drift).
@Test func docExamplesAreValid() throws {
    let doc = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("docs/workflow.md")
    let text = try String(contentsOf: doc, encoding: .utf8)
    let blocks = text.components(separatedBy: "```json5\n").dropFirst().map { $0.components(separatedBy: "```")[0] }
    #expect(blocks.count >= 3)
    var roadmaps = 0
    for block in blocks {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(block.utf8), options: [.json5Allowed]) as? [String: Any])
        // A roadmap example elides its workflow (`{ /* … */ }`).
        if let w = json["workflow"] as? [String: Any], !w.isEmpty || json["roadmap"] == nil,
            case .failure(let p) = WorkflowSpec.parse(w)
        {
            Issue.record("\(p)")
        }
        if let r = json["roadmap"] {
            roadmaps += 1
            if case .failure(let p) = RoadmapSpec.parse(r) { Issue.record("\(p)") }
        }
    }
    #expect(roadmaps >= 1)
}

@Test func gateNamesAreTidied() {
    #expect(WorkflowSpec.gateKey("Design review") == "design-review")
    let recs = WorkflowEngine.records("- Design review: waiting since 2026-10-01 09:30", .regex("^- (?<gate>[\\w ]+): (?<status>waiting|approved)(?: since)? (?<at>.+)$"))
    #expect(recs.first?["gate"] == "Design review")
}

@Test func nothingInFlightIsStillAValidDescription() throws {
    let (repo, _) = try sampleRepo()
    try write(repo, ".chiefstew.json", #"{ v: 1, workflow: { builds: { from: "branches", branch: "release/{slug}" } } }"#)
    let r = WorkflowCheck.run(repo: repo.path)
    #expect(r.ok)
    #expect(r.summary == "Valid · nothing in flight right now")
    #expect(r.text.contains("feature/b: doesn't match release/{slug}"))
}

/// Chief Stew must never name the private repos it was developed against, or carry their data
/// or a developer's home path. The words are assembled here so this file doesn't match itself.
@Test func noPrivateNamesAnywhere() throws {
    let forbidden = [["c", "a", "s", "s", "e", "t", "t", "a"], ["m", "a", "t", "t", "h", "e", "w", "h", "e", "y", "w", "o", "o", "d"]]
        .map { $0.joined() }
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let fm = FileManager.default
    var hits: [String] = []
    for top in ["Sources", "Tests", "docs", "dev", "README.md", "CLAUDE.md", "build.sh", "Package.swift"] {
        let url = root.appendingPathComponent(top)
        let files = fm.enumerator(at: url, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [url]
        for file in files where !file.hasDirectoryPath {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for word in forbidden where text.lowercased().contains(word) {
                hits.append("\(file.path.replacingOccurrences(of: root.path + "/", with: "")): \(word)")
            }
        }
    }
    #expect(hits.isEmpty, "\(hits)")
}

/// Suggestions must never look inside macOS-protected folders: doing so raises a permission
/// prompt just to fill a menu (and sends the wizard behind other windows).
@Test func suggestionsSkipProtectedFolders() throws {
    let home = try tempDir()
    for path in ["my-app/.git", "Developer/web/.git", "Documents/secret/.git", "Desktop/x/.git", "Downloads/y/.git", "Developer/notes"] {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    let found = RepoSuggestions.find(home: home.path).map { URL(fileURLWithPath: $0).lastPathComponent }
    #expect(found.sorted() == ["my-app", "web"])
}

// MARK: - Builds the first version missed (found when a real repo was set up)

@Test func recentRemoteOnlyBuildsCountByDefault() throws {
    let (repo, _) = try sampleRepo()
    let origin = repo.deletingLastPathComponent().appendingPathComponent("origin.git")
    try run(repo.deletingLastPathComponent(), "init", "-q", "--bare", origin.path)
    try run(repo, "remote", "add", "origin", origin.path)
    try run(repo, "checkout", "-q", "-b", "feature/r", "main")
    try run(repo, "commit", "-q", "--allow-empty", "-m", "remote work")
    try run(repo, "push", "-q", "origin", "feature/r", "main")
    try run(repo, "checkout", "-q", "main")
    try run(repo, "branch", "-q", "-D", "feature/r")  // only origin/feature/r is left

    // By default a recently active remote-only build counts, with no setting needed.
    let auto = try WorkflowSpec.parse(["builds": ["from": "branches", "branch": "feature/{slug}"]]).get()
    #expect(WorkflowEngine(repo: repo.path, spec: auto).run().report.builds.contains { $0.slug == "r" && $0.worktree == nil })
    let off = try WorkflowSpec.parse(["builds": ["from": "branches", "branch": "feature/{slug}", "remote": false]]).get()
    #expect(!WorkflowEngine(repo: repo.path, spec: off).run().report.builds.map(\.slug).contains("r"))
}

@Test func anAgentWorktreeOnAnotherBranchCountsForItsBuild() throws {
    let (repo, wt) = try sampleRepo()
    try run(wt, "add", ".")
    try run(wt, "commit", "-q", "-m", "a work")
    let agentWT = repo.deletingLastPathComponent().appendingPathComponent("agent-1")
    try run(repo, "worktree", "add", "-q", "-b", "worktree-agent-1", agentWT.path, "feature/a")
    try write(repo, ".chiefstew.json", typical)
    let spec = try RepoConfig.load(repo: repo.path).get().workflow!
    let a = try #require(WorkflowEngine(repo: repo.path, spec: spec).run().report.builds.first { $0.slug == "a" })
    #expect(a.worktrees == [PathMatch.normalize(agentWT.path)])

    // An agent asking a question in that worktree shows against build "a".
    let agent = AgentState(
        session: "s", repo: repo.path, path: PathMatch.normalize(agentWT.path), lastEventAt: Date(),
        lastKind: "agent.needs_input", needsInput: .init(since: Date(), message: "ok?"), agent: "claude-code")
    let board = Board.make(
        repos: [RepoSnapshot(path: repo.path, status: StatusReport(builds: [a]))], agents: [agent], now: Date())
    #expect(board.needsYou.contains { $0.card?.slug == "a" && $0.id == "agent-s" })
}

@Test func aGateFileOnAnUncheckedOutBranchIsReadFromGit() throws {
    let (repo, _) = try sampleRepo()
    try run(repo, "checkout", "-q", "feature/c")
    try write(repo, "docs/features/c/STATUS.md", "Ready\nReview: waiting\n")
    try write(repo, "docs/features/c/PR.md", "the PR")
    try run(repo, "add", ".")
    try run(repo, "commit", "-q", "-m", "c ready")
    try run(repo, "checkout", "-q", "main")
    try write(repo, ".chiefstew.json", typical)
    let spec = try RepoConfig.load(repo: repo.path).get().workflow!
    let c = try #require(WorkflowEngine(repo: repo.path, spec: spec).run().report.builds.first { $0.slug == "c" })
    let gate = try #require(c.gates.first)
    #expect(gate.artefact == nil)
    #expect(gate.artefactRef == "feature/c:docs/features/c/PR.md")
}

@Test func oldRemoteOnlyBuildsAreSkippedByDefaultWithAReason() throws {
    let (repo, _) = try sampleRepo()
    let origin = repo.deletingLastPathComponent().appendingPathComponent("origin.git")
    try run(repo.deletingLastPathComponent(), "init", "-q", "--bare", origin.path)
    try run(repo, "remote", "add", "origin", origin.path)
    try run(repo, "checkout", "-q", "-b", "feature/old", "main")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", repo.path, "commit", "-q", "--allow-empty", "-m", "old work"]
    p.environment = [
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@t",
        "GIT_AUTHOR_DATE": "2025-01-01T12:00:00", "GIT_COMMITTER_DATE": "2025-01-01T12:00:00", "HOME": NSTemporaryDirectory(),
    ]
    try p.run()
    p.waitUntilExit()
    try run(repo, "push", "-q", "origin", "feature/old")
    try run(repo, "checkout", "-q", "main")
    try run(repo, "branch", "-q", "-D", "feature/old")
    let spec = try WorkflowSpec.parse(["builds": ["from": "branches", "branch": "feature/{slug}"]]).get()
    let r = WorkflowEngine(repo: repo.path, spec: spec).runExplained()
    #expect(!r.report.builds.map(\.slug).contains("old"))
    #expect(r.skipped.contains { $0.hasPrefix("origin/feature/old: only on origin, no commits for") })
    let all = try WorkflowSpec.parse(["builds": ["from": "branches", "branch": "feature/{slug}", "remote": true]]).get()
    #expect(WorkflowEngine(repo: repo.path, spec: all).run().report.builds.map(\.slug).contains("old"))
}

@Test func stateFromASectionStillLinksTheRealFile() throws {
    let (repo, wt) = try sampleRepo()
    try write(repo, ".chiefstew.json", """
        {
          v: 1,
          workflow: {
            builds: { from: "branches", branch: "feature/{slug}", folder: "docs/features/{slug}" },
            state:  { file: "PLAN.md", section: "Phases", pick: "first-line" },
          },
        }
        """)
    let config = try RepoConfig.load(repo: repo.path).get()
    let a = try #require(WorkflowEngine(repo: repo.path, spec: config.workflow!).run().report.builds.first)
    #expect(!a.state.isEmpty)
    // The section belongs in check's messages, not in the path "Open progress" opens.
    let progress = try #require(a.progress)
    #expect(progress == PathMatch.normalize(wt.path) + "/docs/features/a/PLAN.md")
    #expect(FileManager.default.fileExists(atPath: progress))
}

/// A lane the repo states is reported; the default only picks the route.
@Test func aDefaultLaneDecidesTheRouteButIsNotReported() throws {
    let (repo, _) = try sampleRepo()
    try write(repo, "work/012_login/STATUS.md", "Designing\nLane: fast\n")
    try write(repo, "work/012_login/PLAN.md", plan)
    try write(repo, "work/013_billing/STATUS.md", "Building\n")
    try write(repo, "work/013_billing/PLAN.md", plan)
    let spec = try WorkflowSpec.parse([
        "builds": ["from": "folders", "folder": "work/{num}_{slug}"],
        "lane": ["file": "STATUS.md", "match": "^Lane: (?<lane>\\w+)", "default": "full"],
        "phases": [
            "file": "PLAN.md", "section": "Phases", "list": "checkboxes",
            "skip": ["lane": "full", "phases": [2]],
        ],
    ]).get()
    let rows = WorkflowEngine(repo: repo.path, spec: spec).run().report.builds
    #expect(rows.map(\.lane) == ["fast", nil])
    #expect(rows[0].phases?.map { $0.skipped == true } == [false, false, false])
    #expect(rows[1].phases?.map { $0.skipped == true } == [false, true, false])  // the default's route
}

private func commit(_ dir: URL, as name: String, _ email: String, _ message: String) throws {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", dir.path, "commit", "-q", "-m", message]
    p.environment = [
        "GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email, "GIT_COMMITTER_NAME": name,
        "GIT_COMMITTER_EMAIL": email, "HOME": NSTemporaryDirectory(),
    ]
    p.standardOutput = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
}

/// Teammates merge on origin while the local main sits still: merged and squash-merged builds
/// leave the list, a teammate's open build is marked as theirs, and origin-only rows say so.
@Test func originsMainCountsAndAuthorsAreKnown() throws {
    let (repo, _) = try sampleRepo()
    let origin = repo.deletingLastPathComponent().appendingPathComponent("origin.git")
    try run(repo.deletingLastPathComponent(), "init", "-q", "--bare", origin.path)
    try run(repo, "remote", "add", "origin", origin.path)
    try run(repo, "config", "user.email", "me@example.com")
    try run(repo, "push", "-q", "origin", "main")
    try run(repo, "remote", "set-head", "origin", "main")

    // Three origin-only builds: merged, squash-merged, and a teammate's still open; one of mine.
    for (slug, who) in [("merged", "Dana"), ("squashed", "Dana"), ("theirs", "Dana"), ("mine", "Me")] {
        try run(repo, "checkout", "-q", "-b", "feature/\(slug)", "main")
        try write(repo, "\(slug).txt", slug)
        try run(repo, "add", ".")
        try commit(repo, as: who, who == "Me" ? "me@example.com" : "dana@example.com", slug)
        try run(repo, "push", "-q", "origin", "feature/\(slug)")
        try run(repo, "checkout", "-q", "main")
        try run(repo, "branch", "-q", "-D", "feature/\(slug)")
    }
    // On origin's main: a real merge and a squash. The local main is left behind.
    try run(repo, "checkout", "-q", "-b", "upstream", "main")
    try run(repo, "merge", "-q", "--no-ff", "-m", "merge", "origin/feature/merged")
    try run(repo, "merge", "-q", "--squash", "origin/feature/squashed")
    try commit(repo, as: "Dana", "dana@example.com", "squashed (#2)")
    try run(repo, "push", "-q", "origin", "upstream:main")
    try run(repo, "checkout", "-q", "main")
    try run(repo, "fetch", "-q", "origin")

    let spec = try WorkflowSpec.parse(["builds": ["from": "branches", "branch": "feature/{slug}"]]).get()
    let r = WorkflowEngine(repo: repo.path, spec: spec).runExplained()
    let slugs = r.report.builds.map(\.slug)
    #expect(!slugs.contains("merged") && !slugs.contains("squashed"))
    #expect(r.skipped.contains("origin/feature/merged: already merged into origin/main"))
    #expect(r.skipped.contains("origin/feature/squashed: already merged into origin/main"))
    let theirs = try #require(r.report.builds.first { $0.slug == "theirs" })
    #expect(theirs.author == "Dana" && theirs.mine == false && theirs.onlyOnOrigin == true)
    #expect(r.report.builds.first { $0.slug == "mine" }?.mine == true)
    #expect(r.report.fetchedAt != nil)
}

@Test func branchLinksForGitHubRemotes() {
    let link = "https://github.com/acme/app/tree/build/12-x"
    #expect(WorkflowEngine.branchURL(origin: "git@github.com:acme/app.git", branch: "build/12-x") == link)
    #expect(WorkflowEngine.branchURL(origin: "https://github.com/acme/app", branch: "build/12-x") == link)
    #expect(WorkflowEngine.branchURL(origin: "ssh://git@github.com/acme/app.git", branch: "build/12-x") == link)
    // An ssh host alias (one per GitHub account) resolves to github.com.
    #expect(
        WorkflowEngine.branchURL(origin: "git@work:acme/app.git", branch: "build/12-x") {
            $0 == "work" ? "github.com" : $0
        } == link)
    #expect(WorkflowEngine.branchURL(origin: "git@gitlab.com:acme/app.git", branch: "x") == nil)
    #expect(WorkflowEngine.branchURL(origin: "/srv/git/app.git", branch: "x") == nil)
}

// MARK: - Tasks that belong to a phase

/// A plan's tasks are built in one phase; once the build moves on (into review, say), its finished
/// count shouldn't follow it there.
@Test func tasksWithAPhaseShowOnlyWhileItIsActive() throws {
    let (repo, _) = try sampleRepo()
    func spec(_ phase: Any?) throws -> WorkflowSpec {
        var tasks: [String: Any] = ["file": "PLAN.md", "section": "Tasks", "count": "checkboxes"]
        tasks["phase"] = phase
        return try WorkflowSpec.parse([
            "builds": ["from": "branches", "branch": "feature/{slug}", "folder": "docs/features/{slug}"],
            "phases": ["file": "PLAN.md", "section": "Phases", "list": "checkboxes"],
            "tasks": tasks,
        ] as [String: Any]).get()
    }
    // feature/a: Design done, Build active (phase 2), 2 of 3 tasks ticked.
    func run(_ phase: Any?) throws -> (TaskCount?, String) {
        let r = WorkflowEngine(repo: repo.path, spec: try spec(phase)).runExplained()
        let a = try #require(r.report.builds.first { $0.slug == "a" })
        let note = r.diagnostics.first { $0.slug == "a" }?.notes.first { $0.field == "tasks" }?.detail ?? ""
        return (a.tasks, note)
    }
    #expect(try run(nil).0 == TaskCount(done: 2, total: 3))
    #expect(try run(2).0 == TaskCount(done: 2, total: 3))
    #expect(try run([1, 2]).0 == TaskCount(done: 2, total: 3))
    let (hidden, note) = try run(3)
    #expect(hidden == nil)
    #expect(note.hasSuffix("2/3, shown only in phase 3 (now in phase 2)"))

    guard case .failure(let p) = WorkflowSpec.parse([
        "builds": ["from": "worktrees"], "tasks": ["file": "PLAN.md", "count": "checkboxes", "phase": "review"],
    ] as [String: Any]) else { Issue.record("expected a problem"); return }
    #expect(p.list.map(\.path) == ["workflow.tasks.phase"])
}

@Test func theSetupPromptAsksForAStateLineThatMoves() {
    let prompt = SetupPrompt.make(
        repo: "/Users/you/my-app", config: RepoConfig(status: nil, sweep: nil, source: .none), problem: nil,
        contract: nil, workflowDoc: nil, cli: "chiefstew")
    #expect(prompt.contains("Check that the state line really moves"))
    #expect(prompt.contains("never \"step 1\""))
    #expect(prompt.contains("give `tasks` that phase's number as `phase`"))
}

// MARK: - A build's time budget

@Test func theBudgetIsReadFromTheBuildsOwnFiles() throws {
    let (repo, wt) = try sampleRepo()
    try write(wt, "docs/features/a/STATUS.md", "In review\nSize: L (2h)\n")
    func spec(_ match: String) throws -> WorkflowSpec {
        try WorkflowSpec.parse([
            "builds": ["from": "branches", "branch": "feature/{slug}", "folder": "docs/features/{slug}"],
            "budget": ["file": "STATUS.md", "match": match],
        ] as [String: Any]).get()
    }
    let r = WorkflowEngine(repo: repo.path, spec: try spec(#"^Size: (?<label>\w+) \((?<hours>[\d.]+)h\)"#)).runExplained()
    #expect(r.report.builds.first { $0.slug == "a" }?.budget == Budget(hours: 2, label: "L"))
    #expect(r.report.builds.first { $0.slug == "c" }?.budget == nil)  // its STATUS.md has no Size line
    let note = r.diagnostics.first { $0.slug == "a" }?.notes.first { $0.field == "budget" }
    #expect(note?.ok == true && note?.detail.hasSuffix("→ L · 2h") == true)

    guard case .failure(let p) = WorkflowSpec.parse([
        "builds": ["from": "worktrees"], "budget": ["file": "STATUS.md", "match": "^Size: (\\w+)"],
    ] as [String: Any]) else { Issue.record("expected a problem"); return }
    #expect(p.list.map(\.path) == ["workflow.budget.match"])
    #expect(Budget(hours: 0.5).text == "30 min" && Budget(hours: 4).text == "4h" && Budget(hours: 1.5).text == "1h 30m")
}

/// Folder builds share the main checkout: a finished one leaves status (a folder is never merged),
/// each reports its own folder and title, and its activity is its own folder's, uncommitted or not.
@Test func folderBuildsAreDoneTitledAndOwnTheirFolder() throws {
    let (repo, _) = try sampleRepo()
    try write(repo, "work/012_login/STATUS.md", "# 012 · Login screen\n\nAccepted in DR-12\n")
    try write(repo, "work/013_billing/STATUS.md", "# 013 · Billing\n\nResearch: 2 agents running\n")
    let later = Date().addingTimeInterval(120)
    try FileManager.default.setAttributes(
        [.modificationDate: later], ofItemAtPath: repo.appendingPathComponent("work/013_billing/STATUS.md").path)
    let spec = try WorkflowSpec.parse([
        "builds": ["from": "folders", "folder": "work/{num}_{slug}"],
        "state": ["file": "STATUS.md"],
        "title": ["file": "STATUS.md", "match": "^# \\d+ · (?<title>.+)$"],
        "done": ["state": "^Accepted"],
    ]).get()
    let r = WorkflowEngine(repo: repo.path, spec: spec).runExplained()
    #expect(r.report.builds.map(\.num) == ["013"])
    #expect(r.skipped.contains { $0.hasPrefix("012: done") })
    let row = try #require(r.report.builds.first)
    #expect(row.title == "Billing")
    #expect(row.folder == PathMatch.normalize(repo.path) + "/work/013_billing")
    #expect(row.worktree == PathMatch.normalize(repo.path))
    #expect(row.behind == nil)
    #expect(abs((row.changedAt ?? .distantPast).timeIntervalSince(later)) < 1)
    #expect(row.changedAt! > row.lastCommitAt)
}

/// A branch is done when it's merged; done but not merged is `closed`, which still needs you.
@Test func doneIsOnlyForFolderBuilds() {
    guard case .failure(let p) = WorkflowSpec.parse([
        "builds": ["from": "branches", "branch": "feature/{slug}"], "done": ["state": "^Done"],
    ]) else {
        Issue.record("expected a problem")
        return
    }
    #expect(p.list.map(\.path) == ["workflow.done"])
}

/// A phase under way that started on a date alone is called out: its clock would count from midnight.
@Test func checkCallsOutAStartWithADateOnly() throws {
    let (repo, _) = try sampleRepo()
    let list = "^- \\[(?<done>[ x])\\] (?<n>\\d)\\. (?<name>\\w+)(?: \\(started (?<started>[\\d: -]+?)(?: → (?<doneAt>[\\d: -]+))?\\))?$"
    try write(repo, "work/012_login/STATUS.md", "- [x] 1. Draft (started 2026-10-05 → 2026-10-05)\n- [ ] 2. Build (started 2026-10-06)\n")
    try write(repo, "work/013_billing/STATUS.md", "- [ ] 1. Draft (started 2026-10-06 09:10)\n")
    let spec = try WorkflowSpec.parse([
        "builds": ["from": "folders", "folder": "work/{num}_{slug}"],
        "phases": ["file": "STATUS.md", "list": list],
    ]).get()
    let notes = WorkflowEngine(repo: repo.path, spec: spec).run().diagnostics.map { $0.notes.first { $0.field == "phases" }!.detail }
    #expect(notes[0].contains("Build started with a date only"))
    #expect(!notes[0].contains("Draft started"))  // done: nothing to fix now
    #expect(!notes[1].contains("date only"))
}
