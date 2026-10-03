import AppKit
@testable import ChiefStewCore
@testable import ChiefStewUI
import SwiftUI
import Testing

// The window's pages, rendered offscreen like the panel: each roadmap state, All repos and Left
// behind. PNGs go to the same folder as the panel's, for checking by eye.

let roadmapText = """
    ## Stage 1: Accounts

    | #   | Build        | Status          |
    | --- | ------------ | --------------- |
    | 161 | sign_up      | Done 2026-08-01 |
    | 162 | sign_in      | Done 2026-08-03 |

    ## Stage 2: Search

    | #   | Build          | Status                       |
    | --- | -------------- | ---------------------------- |
    | 170 | search_basics  | Done 2026-09-12              |
    | 173 | search_index   | Planned                      |
    | 176 | saved_searches | Next (waits for 173)         |
    | 177 | search_filters | In progress                  |
    | 178 | typo_tolerance |                              |
    | —   | voice_search   | an idea, not numbered yet    |
    | 179 | search_v0      | Merged into 173              |

    ## Stage 3: Checkout

    | #   | Build          | Status  |
    | --- | -------------- | ------- |
    | 174 | checkout_flow  | Planned |
    | 180 | gift_cards     | Planned |
    | 181 | wish_lists     | Dropped |
    """

let roadmapSpec = try! RoadmapSpec.parse([
    "file": "docs/roadmap.md",
    "group": ["match": "^Stage \\d+: (?<name>.+)"],
    "columns": ["num": "#", "name": "Build", "status": "Status"],
    "status": [
        "done": "^Done(?: (?<date>[\\d-]+))?", "folded": "^Merged into", "dropped": "^Dropped",
        "active": "^In progress", "next": "^Next", "planned": "^Planned",
    ],
] as [String: Any]).get()

func withRoadmap(_ snap: RepoSnapshot, fromOrigin: Bool = true) -> RepoSnapshot {
    var s = snap
    var r = RoadmapParser.parse(roadmapText, roadmapSpec)
    r.file = "docs/roadmap.md"
    r.ref = fromOrigin ? "origin/main" : "main"
    r.fromOrigin = fromOrigin
    r.fetchedAt = fromOrigin ? ago(40) : nil
    s.roadmapConfigured = true
    s.roadmap = r
    return s
}

func repoViews(_ snaps: [RepoSnapshot]) -> [RepoView] {
    RepoView.make(repos: snaps, board: Board.make(repos: snaps, agents: [idle175], claude: claudeSessions, now: now))
}

let leftSweep = SweepReport(
    databases: .init(checked: true, leaked: ["myapp_wt_fix_b"]),
    routes: [.init(hostname: "fix-b.api.my-app.localhost", reason: "process 5512 is gone")],
    processes: [.init(pid: 67816, cwd: "\(wt)/129")],
    cleanup: ["make clean-dbs"])

func live(_ sweep: SweepReport? = nil) -> RepoSnapshot {
    RepoSnapshot(
        path: repo, status: StatusReport(builds: [b173, b174, b175]), statusAt: ago(0.2), sweep: sweep,
        sweepAt: sweep == nil ? nil : ago(6))
}

@MainActor func renderPage<V: View>(_ view: V, _ name: String) throws {
    for dark in [false, true] {
        let image = try #require(render(view.frame(width: 680).font(.system(size: 13)), dark: dark))
        #expect(image.size.width == 680)
        #expect(image.size.height > 40)
        try write(image, "window-\(name)\(dark ? "-dark" : "")")
    }
}

@Test @MainActor func roadmapPagesRender() throws {
    let ready = repoViews([withRoadmap(live())])[0]
    guard case .ready(let plan) = ready.plan else { Issue.record("expected a plan"); return }
    // 173 and 174 are live (status reports them), 175 too but it's not on the roadmap.
    #expect(Set(plan.live) == ["173", "174"])
    #expect(plan.upNext.map(\.num) == ["176"])
    #expect(plan.disagreements.map(\.num) == ["177"])
    #expect(plan.shipped.map(\.name) == ["Accounts"])
    try renderPage(RoadmapView(repo: ready, now: now, actions: PanelActions()), "roadmap")

    var none = live()
    none.roadmapConfigured = false
    try renderPage(RoadmapView(repo: repoViews([none])[0], now: now, actions: PanelActions()), "roadmap-none")

    var broken = live()
    broken.roadmapConfigured = true
    broken.roadmapError = RepoError(
        message: "docs/roadmap.md isn't on main", since: ago(3),
        hint: "The roadmap is read from main in git, so it must be committed there. Check the path in .chiefstew.json.")
    try renderPage(RoadmapView(repo: repoViews([broken])[0], now: now, actions: PanelActions()), "roadmap-problem")

    var loading = live()
    loading.roadmapConfigured = true
    try renderPage(RoadmapView(repo: repoViews([loading])[0], now: now, actions: PanelActions()), "roadmap-loading")
}

@Test @MainActor func allReposAndLeftBehindRender() throws {
    let other = RepoSnapshot(path: "/Users/you/other-app", status: StatusReport(builds: []), statusAt: ago(0.2))
    let views = repoViews([withRoadmap(live(leftSweep)), other])
    try renderPage(AllReposView(repos: views, now: now, actions: PanelActions()), "all-repos")
    let r = views[0]
    #expect(r.left.count == 3 && r.cleanup == ["make clean-dbs"])
    try renderPage(
        LeftBehindList(items: r.left, cleanup: r.cleanup, notes: r.leftNotes, sweptAt: r.sweptAt, now: now, actions: PanelActions()),
        "left-behind")
    try renderPage(
        LeftBehindList(items: [], cleanup: [], notes: [], sweptAt: nil, now: now, actions: PanelActions()),
        "left-behind-none")
}

@Test func thePanelSumsUpLeftBehindAndSaysWhereDetailsGo() throws {
    let board = try #require(states.first { $0.0 == "4-left-behind" }?.1)
    #expect(board.leftSummary == "1 leaked database, 2 processes in deleted folders, 1 stray route")
    #expect(board.leftTarget == WindowSelection(repo: repo, tab: .leftBehind))

    // Leftovers in two repos: Details opens All repos.
    let other = "/Users/you/other-app"
    let two = Board.make(
        repos: [
            live(leftSweep),
            RepoSnapshot(path: other, status: StatusReport(builds: []), statusAt: ago(0.2), sweep: leftSweep, sweepAt: ago(6)),
        ], agents: [], now: now)
    #expect(two.leftTarget == WindowSelection(repo: nil, tab: .leftBehind))
    #expect(two.leftSummary == "2 leaked databases, 2 processes in deleted folders, 2 stray routes")
}

/// The build row's clock against its budget: within (`L · 1h 42m of 2h`) and over.
@Test @MainActor func budgetClockRenders() throws {
    var within = b173
    within.budget = Budget(hours: 2, label: "L")
    var over = b175
    over.budget = Budget(hours: 0.25, label: "S")
    let board = Board.make(
        repos: [RepoSnapshot(path: repo, status: StatusReport(builds: [within, over]), statusAt: ago(0.2))],
        agents: [], now: now)
    #expect(board.overBudget.map(\.num) == ["175"])
    for dark in [false, true] {
        let image = try #require(render(PanelView(board: board, now: now), dark: dark))
        #expect(image.size.width == PanelView.width)
        try write(image, "panel-budget\(dark ? "-dark" : "")")
    }
}
