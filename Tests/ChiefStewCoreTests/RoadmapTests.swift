@testable import ChiefStewCore
import Foundation
import Testing

// The roadmap (contract § 4c, docs/workflow.md § Roadmap): the description, the markdown reader,
// the ref it's read from, `check`, and the join with status.

private func git(_ dir: URL, _ args: String...) throws {
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

private func commit(_ repo: URL, _ message: String) throws {
    try git(repo, "add", ".")
    try git(repo, "commit", "-q", "-m", message)
}

private let plan = """
    # Roadmap

    ## Where we are

    ### Sequencing

    | #   | Build       | Status |
    | --- | ----------- | ------ |
    | 013 | saved_cards | Next   |

    ## Anytime pool · pick up whenever

    | #   | Build        | Status            |
    | --- | ------------ | ----------------- |
    | 090 | faster_tests | Planned           |

    ## Stage 1: Basics

    ### Stage 1.1: Accounts

    | #   | Build          | Status                         |
    | --- | -------------- | ------------------------------ |
    | 001 | sign_up        | **Done 2026-08-01**            |
    | 002 | sign_in        | ✓ `Done` 2026-08-03 (notes)    |

    ## Stage 2: Checkout

    | #   | Build          | Status                       |
    | --- | -------------- | ---------------------------- |
    | 011 | cart_summary   | Done 2026-09-12              |
    | 012 | checkout_flow  | In progress                  |
    | 013 | saved_cards    | Next (waits for 012)         |
    | 014 | gift_wrap      | Merged into 011              |
    | 015 | order_emails   | In progress                  |
    | 016 | address_book   |                              |
    | —   | promo_codes    | an idea, not numbered yet    |
    | 017 | coupons        | Dropped                      |

    ```markdown
    ## Stage 9: Not real
    | # | Build | Status |
    | - | ----- | ------ |
    | 999 | inside_a_fence | Done |
    ```

    #### Notes for Stage 2

    | #   | Build        | Status   |
    | --- | ------------ | -------- |
    | 018 | refunds      | Later    |
    | 011 | cart_summary | Done     |
    """

private let spec: RoadmapSpec = {
    let json: [String: Any] = [
        "file": "docs/roadmap.md",
        "group": ["match": "^(?=Stage|Anytime)(?:Stage [\\d.]+: )?(?<name>[^·]+?)\\s*(?:·|$)"],
        "columns": ["num": "#", "name": "Build", "status": "Status"],
        "status": [
            "done": "Done(?: (?<date>[\\d-]+))?", "folded": "^Merged into", "dropped": "^Dropped",
            "active": "^In progress", "next": "^(Next|Ready)", "planned": "^(Planned|Later)",
        ],
    ]
    return try! RoadmapSpec.parse(json).get()
}()

// MARK: - The description

@Test func roadmapSpecReportsEveryProblemWithItsPath() {
    let bad: [String: Any] = [
        "file": "/abs/roadmap.md", "colums": [:], "group": ["match": "("],
        "status": ["done": "[", "shipped": "x"],
    ]
    guard case .failure(let p) = RoadmapSpec.parse(bad) else { Issue.record("expected problems"); return }
    let paths = p.list.map(\.path)
    for path in ["roadmap.file", "roadmap.colums", "roadmap.columns", "roadmap.group.match", "roadmap.status.done", "roadmap.status.shipped"] {
        #expect(paths.contains(path), "\(path) in \(paths)")
    }
}

@Test func aBrokenRoadmapNeverStopsStatus() throws {
    let repo = try tempDir()
    try write(repo, ".chiefstew.json", #"{ v: 1, workflow: { builds: { from: "worktrees" } }, roadmap: { file: "x.md" }, roadmp: {} }"#)
    let c = try RepoConfig.load(repo: repo.path).get()
    #expect(c.workflow != nil)
    #expect(c.roadmap == nil)
    #expect(c.roadmapProblem?.contains("roadmap.columns") == true)
    #expect(c.unknownKeys == ["roadmp"])
}

@Test func aRoadmapOnItsOwnWatchesAgentsOnly() throws {
    let repo = try tempDir()
    try write(repo, ".chiefstew.json", ##"{ v: 1, roadmap: { file: "x.md", columns: { num: "#" } } }"##)
    let c = try RepoConfig.load(repo: repo.path).get()
    #expect(c.roadmap?.file == "x.md")
    #expect(c.status == nil && c.workflow == nil)
}

// MARK: - Reading the markdown

@Test func groupsAreTheClosestMatchingHeadingAtAnyLevel() {
    let r = RoadmapParser.parse(plan, spec)
    #expect(r.groups.map(\.name) == ["Anytime pool", "Accounts", "Checkout"])
    // The H4 notes table sits under Stage 2, so it adds to that group.
    #expect(r.groups[2].rows.map({ $0.num ?? "–" }) == ["011", "012", "013", "014", "015", "016", "–", "017", "018"])
    // The sequencing table repeats rows; no heading above it is a group, so it's skipped.
    #expect(r.skipped.count == 1)
    #expect(r.skipped[0].reason.contains("\"Sequencing\": no heading above it matches"))
    // Nothing inside a code fence is read.
    #expect(!r.rows.contains { $0.num == "999" })
}

@Test func statusRulesRunOnPlainTextInOrder() {
    let r = RoadmapParser.parse(plan, spec)
    func row(_ num: String) -> Roadmap.Row? { r.rows.first { $0.num == num } }
    #expect(row("001")?.status == .done && row("001")?.text == "Done 2026-08-01")
    #expect(row("001")?.date == LooseDate.parse("2026-08-01"))
    #expect(row("002")?.status == .done && row("002")?.text == "✓ Done 2026-08-03 (notes)")
    #expect(row("012")?.status == .active)
    #expect(row("013")?.status == .next && row("013")?.text == "Next (waits for 012)")
    #expect(row("014")?.status == .folded)
    #expect(row("017")?.status == .dropped)
    #expect(row("016")?.status == .planned && row("016")?.text == "")
    #expect(row("018")?.status == .planned)
    // Only text no rule explains is listed as unmatched; "Planned"/"Later" match the planned rule.
    #expect(r.unmatched.map(\.name) == ["promo_codes"])
}

@Test func unnumberedRowsAreKeptAndDuplicatesAreReported() {
    let r = RoadmapParser.parse(plan, spec)
    let promo = r.rows.first { $0.name == "promo_codes" }
    #expect(promo != nil && promo?.num == nil)
    #expect(r.duplicates == [.init(num: "011", line: 51, firstLine: 30)])
}

@Test func tableCellsHandlePipesAndMissingOuterPipes() {
    #expect(RoadmapParser.cells("| a | b \\| c | `x | y` |") == ["a", "b | c", "`x | y`"])
    #expect(RoadmapParser.cells("a | b") == ["a", "b"])
    #expect(RoadmapParser.isDelimiter("| --- | :-: |") && RoadmapParser.isDelimiter("---|---"))
    #expect(!RoadmapParser.isDelimiter("| a | b |"))
    #expect(RoadmapParser.plain("**[Done](x.md)** ~~old~~ `code`") == "Done old code")
}

@Test func aTableWithoutTheNamedColumnsIsSkippedWithItsHeader() {
    let md = "## Stage 1: A\n\n| # | Build | Kind |\n|---|---|---|\n| 001 | x | y |\n"
    let r = RoadmapParser.parse(md, spec)
    #expect(r.rows.isEmpty)
    #expect(r.skipped.first?.reason == "under \"Stage 1: A\": no \"Status\" column (has #, build, kind)")
}

@Test func withoutGroupEveryTableIsOneGroup() {
    var s = spec
    s.groupMatch = nil
    let r = RoadmapParser.parse(plan, s)
    #expect(r.groups.count == 1 && r.groups[0].name == "")
    #expect(r.skipped.isEmpty)
    // The sequencing table now comes first, so its 013 wins and the later one is the duplicate.
    #expect(r.rows.first { $0.num == "013" }?.text == "Next")
}

@Test func aSectionLimitsWhatIsRead() {
    var s = spec
    s.section = "Stage 2"
    let r = RoadmapParser.parse(plan, s)
    #expect(r.groups.map(\.name) == ["Checkout"])
    s.section = "Nowhere"
    #expect(RoadmapParser.parse(plan, s).skipped.first?.reason == "no \"Nowhere\" section")
}

// MARK: - Joined with status

@Test func statusWinsAndTheFileSuppliesTheRest() {
    let r = RoadmapParser.parse(plan, spec)
    // 012 is in flight; so is 011, which the file already calls done (status wins); 015 is
    // marked in progress but status doesn't report it.
    let p = RoadmapPlan.join(r, liveNums: ["011", "012"])
    #expect(p.live == ["011", "012"])
    #expect(p.disagreements.map(\.num) == ["015"])
    #expect(p.upNext.map(\.num) == ["013"])
    #expect(Set(p.hidden.compactMap(\.num)) == ["014", "017"])
    let checkout = p.groups.first { $0.name == "Checkout" }
    #expect(checkout?.done == 0)  // 011 is live, so it isn't counted done
    #expect(checkout?.toDo == 7)  // 011, 012, 013, 015, 016, promo_codes, 018
    #expect(p.groups.map(\.name) == ["Anytime pool", "Checkout"])
    #expect(p.shipped.map(\.name) == ["Accounts"])
    #expect(p.shipped.first?.latest == LooseDate.parse("2026-08-03"))
}

@Test func aFoldedRowThatStatusStillReportsIsLive() {
    let r = RoadmapParser.parse(plan, spec)
    let p = RoadmapPlan.join(r, liveNums: ["014"])
    #expect(p.live == ["014"])
    #expect(!p.hidden.contains { $0.num == "014" })
}

@Test func shippedGroupsAreNewestFirst() {
    let md = """
        ## Stage 1: Old
        | # | Build | Status |
        |---|---|---|
        | 001 | a | Done 2026-01-01 |
        ## Stage 2: Undated
        | # | Build | Status |
        |---|---|---|
        | 002 | b | Done |
        ## Stage 3: New
        | # | Build | Status |
        |---|---|---|
        | 003 | c | Done 2026-03-01 |
        """
    let p = RoadmapPlan.join(RoadmapParser.parse(md, spec), liveNums: [])
    #expect(p.shipped.map(\.name) == ["New", "Old", "Undated"])
    #expect(p.groups.isEmpty)
}

// MARK: - Reading it from git

/// A repo with the roadmap committed on main, and an origin whose main is ahead.
private func roadmapRepo() throws -> URL {
    let repo = try tempDir().appendingPathComponent("app")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try git(repo, "init", "-q", "-b", "main")
    try write(repo, "docs/roadmap.md", plan)
    try write(repo, ".chiefstew.json", """
        { v: 1, roadmap: { file: "docs/roadmap.md", group: { match: "^(?=Stage|Anytime)(?:Stage [\\\\d.]+: )?(?<name>[^·]+?)\\\\s*(?:·|$)" },
          columns: { num: "#", name: "Build", status: "Status" },
          status: { done: "Done(?: (?<date>[\\\\d-]+))?", next: "^Next", planned: "^(Planned|Later)" } } }
        """)
    try commit(repo, "init")
    return repo
}

@Test func theRoadmapIsReadFromGitNotTheCheckout() throws {
    let repo = try roadmapRepo()
    // Uncommitted edits and a build branch checked out don't change what's read.
    try git(repo, "checkout", "-q", "-b", "build/x")
    try write(repo, "docs/roadmap.md", "## Stage 1: Changed\n")
    let r = try RoadmapReader.read(repo: repo.path, spec: spec).get()
    #expect(r.ref == "main" && !r.fromOrigin)
    #expect(r.groups.map(\.name) == ["Anytime pool", "Accounts", "Checkout"])
    #expect(r.bytes > 0 && !r.blob.isEmpty)
    #expect(RoadmapReader.source(repo: repo.path, spec: spec) == .init(ref: "main", fromOrigin: false, blob: r.blob))
}

@Test func originsMainIsReadWhenItsFresher() throws {
    let repo = try roadmapRepo()
    let origin = repo.deletingLastPathComponent().appendingPathComponent("origin.git")
    try git(repo.deletingLastPathComponent(), "init", "-q", "--bare", origin.path)
    try git(repo, "remote", "add", "origin", origin.path)
    try git(repo, "push", "-q", "origin", "main")
    try git(repo, "remote", "set-head", "origin", "main")
    // Someone else ships 016 on origin; the local main isn't pulled.
    try git(repo, "checkout", "-q", "-b", "upstream", "main")
    try write(repo, "docs/roadmap.md", plan.replacingOccurrences(of: "| 016 | address_book   |                              |", with: "| 016 | address_book   | Done 2026-09-20              |"))
    try commit(repo, "ship 016")
    try git(repo, "push", "-q", "origin", "upstream:main")
    try git(repo, "checkout", "-q", "main")
    try git(repo, "fetch", "-q", "origin")

    let r = try RoadmapReader.read(repo: repo.path, spec: spec).get()
    #expect(r.ref == "origin/main" && r.fromOrigin && r.fetchedAt != nil)
    #expect(r.rows.first { $0.num == "016" }?.status == .done)

    // A local main with work origin doesn't have yet is read instead.
    try git(repo, "merge", "-q", "--ff-only", "origin/main")
    try write(repo, "local.txt", "x")
    try commit(repo, "local only")
    #expect(try RoadmapReader.read(repo: repo.path, spec: spec).get().ref == "main")
}

@Test func roadmapProblemsSayWhatToDo() throws {
    let repo = try roadmapRepo()
    var missing = spec
    missing.file = "docs/nope.md"
    guard case .failure(let p) = RoadmapReader.read(repo: repo.path, spec: missing) else { Issue.record("expected a problem"); return }
    #expect(p.message == "docs/nope.md isn't on main")

    try write(repo, "docs/roadmap.md", String(repeating: "x", count: WorkflowEngine.maxFile + 1))
    try commit(repo, "big")
    guard case .failure(let big) = RoadmapReader.read(repo: repo.path, spec: spec) else { Issue.record("expected a problem"); return }
    #expect(big.message.contains("the limit is 256 KB"))
    #expect(big.hint?.contains("roadmap.section") == true)

    let empty = try tempDir()
    try git(empty, "init", "-q", "-b", "main")
    guard case .failure(let none) = RoadmapReader.read(repo: empty.path, spec: spec) else { Issue.record("expected a problem"); return }
    #expect(none.message.hasPrefix("no default branch"))
}

@Test func checkExplainsTheRoadmap() throws {
    let repo = try roadmapRepo()
    let r = WorkflowCheck.run(repo: repo.path)
    #expect(r.ok)
    #expect(r.summary == "Agents only · roadmap 12 rows")
    #expect(r.text.contains("Roadmap · docs/roadmap.md on main"))
    #expect(r.text.contains("✓ 12 rows in 3 groups: 3 done, 1 next, 8 planned"))
    #expect(r.text.contains("line 11  Anytime pool: 1 row (0 done, 1 to do)"))
    #expect(r.text.contains("Tables skipped:"))
    #expect(r.text.contains("Status text no rule matched"))
    #expect(r.text.contains("Rows without an ID"))
    #expect(r.text.contains("011 on line 51, first on line 30"))
}
