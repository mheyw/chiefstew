import AppKit
@testable import ChiefStewCore
@testable import ChiefStewUI
import SwiftUI
import Testing

// Offscreen renders of every state. They assert the views
// render at the panel width and write PNGs to $CHIEFSTEW_SNAPSHOTS (default: a temp folder) for
// eyeballing against docs/mockup/states.png.

let now = Date(timeIntervalSince1970: 1_759_240_920)  // 2026-09-30 14:02 UTC
func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

let repo = "/Users/you/my-app"
let wt = "\(repo)/.claude/worktrees"

func phases(_ statuses: [String], skip: Set<Int> = []) -> [PhaseInfo] {
    let names = ["Brief", "Requirements", "Design", "Plan", "Implement", "Review", "Retro"]
    return statuses.enumerated().map { i, s in
        PhaseInfo(
            n: i + 1, name: names[i], status: s, startedAt: i == 0 ? ago(102) : nil,
            skipped: skip.isEmpty ? nil : skip.contains(i + 1))
    }
}

let b173 = BuildRow(
    num: "173", slug: "search_index", state: "Phase 5 — Implement, step 3",
    lastCommitAt: ago(3), worktree: "\(wt)/build-173", behind: 4, lane: "full",
    phases: phases(["done", "done", "done", "done", "active", "pending", "pending"]),
    tasks: TaskCount(done: 6, total: 11), urls: ["admin": "http://build-173.web.my-app.localhost:1355"],
    progress: "\(wt)/build-173/progress.md")
let b175 = BuildRow(
    num: "175", slug: "copy_review", state: "Phase 5 — Implement", lastCommitAt: ago(9),
    worktree: "\(wt)/build-175", lane: "fast",
    phases: phases(["done", "pending", "pending", "pending", "active", "pending", "pending"], skip: [2, 3, 4]).map {
        var p = $0
        if p.n == 1 { p.startedAt = ago(24) }
        return p
    },
    tasks: TaskCount(done: 1, total: 4), progress: "\(wt)/build-175/progress.md")
let b174 = BuildRow(
    num: "174", slug: "checkout_flow", state: "Phase 4 ready — waiting on the Plan gate",
    lastCommitAt: ago(14), worktree: "\(wt)/build-174", lane: "full",
    phases: phases(["done", "done", "done", "active", "pending", "pending", "pending"]),
    gates: [
        GateInfo(gate: "design", status: "approved"),
        GateInfo(
            gate: "plan", status: "waiting", at: ago(12), artefact: "\(wt)/build-174/plan.md",
            approve: "make approve GATE=plan BUILD=174", phase: 4),
    ])
let b172 = BuildRow(
    num: "172", slug: "bulk_actions", state: "Closed 2026-09-28", lastCommitAt: ago(2 * 1440),
    worktree: "\(wt)/build-172", flags: ["closed-unmerged"])

let asking = AgentState(
    session: "s1", repo: repo, path: "\(wt)/build-173", lastEventAt: ago(2),
    lastKind: "agent.needs_input",
    needsInput: .init(since: ago(2), message: "Claude needs your permission to use Bash"))
let idle175 = AgentState(
    session: "s2", repo: repo, path: "\(wt)/build-175", lastEventAt: ago(9), lastKind: "agent.stopped")

/// Claude Code's own status: the 175 session was seen going idle 9 min ago.
let claudeSessions: ClaudeSessions = {
    var c = ClaudeSessions()
    c.update(["s2": .busy], at: ago(30))
    c.update(["s2": .idle], at: ago(9))
    return c
}()

func snapshot(
    builds: [BuildRow], agents: [AgentState] = [], sweep: SweepReport? = nil,
    error: RepoError? = nil
) -> Board {
    Board.make(
        repos: [
            RepoSnapshot(
                path: repo, status: StatusReport(builds: builds), statusAt: ago(0.2),
                statusError: error, sweep: sweep, sweepAt: sweep == nil ? nil : ago(6))
        ], agents: agents, claude: claudeSessions, now: now)
}

let states: [(String, Board)] = [
    ("1-idle", snapshot(builds: [])),
    ("2-in-progress", snapshot(builds: [b173, b175], agents: [idle175])),
    ("3-needs-you", snapshot(builds: [b174, b173, b172, b175], agents: [asking, idle175])),
    (
        "4-left-behind",
        snapshot(
            builds: [b173],
            sweep: SweepReport(
                databases: .init(checked: true, leaked: ["myapp_wt_fix_b"]),
                routes: [.init(hostname: "fix-b.api.my-app.localhost", reason: "process 5512 is gone")],
                processes: [
                    .init(pid: 67816, cwd: "\(wt)/129"), .init(pid: 67818, cwd: "\(wt)/129"),
                ],
                cleanup: ["make clean-dbs", "portless prune"]))
    ),
    (
        "5-stale",
        snapshot(
            builds: [b173],
            error: RepoError(
                message: "node scripts/status.mjs: printed text, not JSON",
                since: ago(1), hint: StatusError.noJSONSupport("").hint))
    ),
    // Appended, not inserted: updateLineRenders uses states[0].
    ("6-no-repos", Board.make(repos: [], agents: [], now: now)),
    ("7-first-poll", Board.make(repos: [RepoSnapshot(path: repo)], agents: [], now: now)),
    (
        "8-failing-no-data",
        Board.make(
            repos: [RepoSnapshot(path: repo, statusError: RepoError(message: "status timed out after 20 s", since: ago(3)))],
            agents: [], now: now)
    ),
    (
        "9-parked",
        snapshot(builds: [
            b173, BuildRow(num: "171", slug: "old_idea", state: "Parked 2026-09-29", lastCommitAt: ago(1440)),
        ])
    ),
    ("10-sweep-failed", sweepFailed()),
    ("11-teammates", teammates()),
    ("12-folder-builds", folderBuilds()),
]

/// A repo whose builds are folders on one checkout: the build shows its title and folder, and
/// Claude working in the checkout is said on it, named for the repo, not guessed onto the build.
func folderBuilds() -> Board {
    let path = "/Users/you/research"
    var row = BuildRow(
        num: "R07", slug: "07", branch: "main", state: "Research: 2 agents running (started 2026-10-06 09:57)",
        lastCommitAt: ago(90), worktree: path, phases: phases(["done", "active", "pending", "pending", "pending"]),
        progress: "\(path)/questions/R07/STATUS.md")
    row.title = "Search ranking"
    row.folder = "\(path)/questions/R07"
    row.changedAt = ago(2)
    let agent = AgentState(session: "r1", repo: path, path: path, lastEventAt: ago(1), lastKind: "agent.resumed")
    var claude = ClaudeSessions()
    claude.update(["r1": .busy], at: ago(5))
    return Board.make(
        repos: [RepoSnapshot(path: path, status: StatusReport(builds: [row]), statusAt: ago(0.2))], agents: [agent],
        claude: claude, now: now)
}

/// A teammate's build closed but not merged, and one of yours known only from origin.
func teammates() -> Board {
    var theirs = BuildRow(
        num: "181", slug: "editor_tidy", branch: "build/181-editor-tidy", state: "Closed 2026-10-03",
        lastCommitAt: ago(25), flags: ["closed-unmerged"])
    theirs.mine = false
    theirs.author = "Dana"
    theirs.onlyOnOrigin = true
    theirs.branchURL = "https://github.com/acme/my-app/tree/build/181-editor-tidy"
    var remote = b175
    remote.branch = "build/175-copy-review"
    remote.worktree = nil
    remote.progress = nil  // the engine only links progress in a checkout
    remote.onlyOnOrigin = true
    var report = StatusReport(builds: [b173, remote, theirs])
    report.fetchedAt = ago(12)
    return Board.make(
        repos: [RepoSnapshot(path: repo, status: report, statusAt: ago(0.2))], agents: [], claude: claudeSessions,
        now: now)
}

func sweepFailed() -> Board {
    var snap = RepoSnapshot(path: repo, status: StatusReport(builds: [b173]), statusAt: ago(0.2))
    snap.sweepError = RepoError(message: "sweep timed out after 20 s", since: ago(4))
    return Board.make(repos: [snap], agents: [], now: now)
}

let outDir: URL = {
    let path = ProcessInfo.processInfo.environment["CHIEFSTEW_SNAPSHOTS"]
        ?? FileManager.default.temporaryDirectory.appendingPathComponent("chiefstew-snapshots").path
    let url = URL(fileURLWithPath: path, isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}()

@MainActor func render<V: View>(_ view: V, dark: Bool = false) -> NSImage? {
    let renderer = ImageRenderer(
        content: view
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, dark ? .dark : .light))
    renderer.scale = 2
    return renderer.nsImage
}

@MainActor func write(_ image: NSImage, _ name: String) throws {
    let tiff = try #require(image.tiffRepresentation)
    let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    try png.write(to: outDir.appendingPathComponent("\(name).png"))
}

@Test(arguments: states.map(\.0))
@MainActor func panelRendersInEveryState(name: String) throws {
    let board = try #require(states.first { $0.0 == name }?.1)
    for dark in [false, true] {
        let image = try #require(render(PanelView(board: board, now: now), dark: dark))
        #expect(image.size.width == PanelView.width)
        #expect(image.size.height > 100)
        try write(image, "panel-\(name)\(dark ? "-dark" : "")")
    }
}

@Test @MainActor func menuBarLabels() throws {
    for (name, board) in states {
        let label = MenuBarLabel(state: board.menu)
            .padding(.horizontal, 8).frame(height: 24)
        let image = try #require(render(label))
        try write(image, "menubar-\(name)")
    }
    print("snapshots: \(outDir.path)")
}

@Test func menuTitlesPerState() {
    let titles = states.map { $0.1.menu.title }
    #expect(
        titles == [
            nil, "173 Implement 6/11 +1", "3 need you", "173 Implement 6/11", "173 Implement 6/11",
            nil, nil, nil, "173 Implement 6/11", "173 Implement 6/11", "173 Implement 6/11 +1",
            "R07 Requirements",
        ])
    #expect(
        states.map { $0.1.menu.warning } == [false, false, false, true, true, false, false, true, false, false, false, false])
}

@Test func approveCommandIsSelfContained() {
    #expect(
        NeedsRow.inWorktree("make approve GATE=plan", "/a/it's here")
            == "cd '/a/it'\\''s here' && make approve GATE=plan")
}

@Test @MainActor func updateLineRenders() throws {
    for (name, banner) in [
        ("available", UpdateBanner.available(label: "v0.3.0")), ("installing", .installing),
        ("failed", .failed(log: "/tmp/update.log")),
    ] {
        let image = try #require(render(PanelView(board: states[0].1, now: now, update: banner)))
        #expect(image.size.width == PanelView.width)
        try write(image, "panel-update-\(name)")
    }
}

/// Retry and Refresh show that they're working, so a repeat of the same error doesn't look ignored.
@Test @MainActor func refreshingRenders() throws {
    let board = try #require(states.first { $0.0 == "5-stale" }?.1)
    let image = try #require(render(PanelView(board: board, now: now, refreshing: true)))
    #expect(image.size.width == PanelView.width)
    try write(image, "panel-refreshing")
}

/// Every menu-bar icon state, enlarged, for checking by eye: idle, in progress, needs you, and
/// each with the warning triangle. All the same width.
@Test @MainActor func menuBarIconStates() throws {
    var sizes = Set<CGFloat>()
    let states: [(String, Bool, Bool, Bool)] = [
        ("idle", false, false, false), ("busy", false, true, false), ("attention", true, true, false),
        ("idle-warn", false, false, true), ("busy-warn", false, true, true), ("attention-warn", true, true, true),
    ]
    let row = HStack(spacing: 24) {
        ForEach(states, id: \.0) { s in
            let img = MenuBarIcon.image(attention: s.1, busy: s.2, warning: s.3)
            VStack {
                Image(nsImage: img).resizable().interpolation(.none).frame(width: img.size.width * 8, height: img.size.height * 8)
                Text(s.0).font(.caption)
            }
        }
    }
    .padding(20).background(Color(white: 0.93))
    for s in states { sizes.insert(MenuBarIcon.image(attention: s.1, busy: s.2, warning: s.3).size.width) }
    #expect(sizes.count == 1)  // fixed width in every state
    let image = try #require(render(row))
    try write(image, "menubar-icon-states")
}

/// "checked just now" was noise (status refreshes every minute); it shows only when stale.
@Test @MainActor func lastCheckedAppearsOnlyWhenStale() throws {
    let fresh = snapshot(builds: [b173])
    var stale = fresh
    stale.checkedAt = now.addingTimeInterval(-6 * 60)
    let a = try #require(render(PanelView(board: fresh, now: now)))
    let b = try #require(render(PanelView(board: stale, now: now)))
    try write(b, "panel-stale-checked")
    #expect(a.size.height == b.size.height)  // same layout; the line sits in the footer row
}
