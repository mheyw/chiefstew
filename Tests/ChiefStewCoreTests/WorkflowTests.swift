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
    #expect(paths.contains("workflow.builds.branch"))
    #expect(paths.contains("workflow.phases.list"))
    #expect(paths.contains("workflow.colour"))
    #expect(paths.contains("workflow.state.line"))  // a guessed key is reported, not ignored
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
    for block in blocks {
        let json = try #require(try JSONSerialization.jsonObject(with: Data(block.utf8), options: [.json5Allowed]) as? [String: Any])
        if case .failure(let p) = WorkflowSpec.parse(json["workflow"] as Any) { Issue.record("\(p)") }
    }
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
