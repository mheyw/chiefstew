import AppKit
@testable import ChiefStewCore
@testable import ChiefStewUI
import SwiftUI
import Testing

// Offscreen renders of every state (the plan's "UI snapshot" tests). They assert the views
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

func snapshot(
    builds: [BuildRow], agents: [AgentState] = [], sweep: SweepReport? = nil,
    error: RepoError? = nil
) -> Board {
    Board.make(
        repos: [
            RepoSnapshot(
                path: repo, status: StatusReport(builds: builds), statusAt: ago(0.2),
                statusError: error, sweep: sweep, sweepAt: sweep == nil ? nil : ago(6))
        ], agents: agents, now: now)
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
]

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
    #expect(titles == [nil, "173 Implement 6/11 +1", "3 need you", "173 Implement 6/11", "173 Implement 6/11"])
    #expect(states.map { $0.1.menu.warning } == [false, false, false, true, true])
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
