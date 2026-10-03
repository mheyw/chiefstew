@testable import ChiefStewCore
import Foundation
import Testing

// MARK: - Agent state (contract § 3.3)

@Test func idleReminderAfterStopIsNotAQuestion() {
    var t = AgentTracker()
    t.apply(event("agent.stopped", at: "2026-09-30T14:00:00Z"))
    var reminder = event("agent.needs_input", at: "2026-09-30T14:01:00Z", message: "Claude is waiting for your input")
    reminder.notificationType = "idle_prompt"
    t.apply(reminder)
    reminder.notificationType = nil  // older Claude Code: recognised by its text
    t.apply(reminder)
    let s = try! #require(t.current(now: iso("2026-09-30T14:02:00Z")).first)
    #expect(s.needsInput == nil)
    #expect(s.isIdle)
}

@Test func permissionPromptsAndQuestionsAreNeedsInput() {
    for type in ["permission_prompt", "elicitation_dialog", nil] as [String?] {
        var t = AgentTracker()
        var e = event("agent.needs_input", at: "2026-09-30T14:00:00Z", message: "Claude needs your permission to use Bash")
        e.notificationType = type
        t.apply(e)
        #expect(t.current(now: iso("2026-09-30T14:01:00Z")).first?.needsInput != nil)
    }
}

@Test func answeredPermissionPromptIsClearedByStop() {
    var t = AgentTracker()
    t.apply(event("agent.needs_input", at: "2026-09-30T14:00:00Z"))
    t.apply(event("agent.stopped", at: "2026-09-30T14:03:00Z"))
    #expect(t.current(now: iso("2026-09-30T14:04:00Z")).first?.needsInput == nil)
}

@Test func resumedClears() {
    var t = AgentTracker()
    t.apply(event("agent.needs_input", at: "2026-09-30T14:00:00Z"))
    t.apply(event("agent.resumed", at: "2026-09-30T14:05:00Z"))
    #expect(t.current(now: iso("2026-09-30T14:06:00Z")).first?.needsInput == nil)
}

@Test func aLateOlderEventChangesNothing() {
    var t = AgentTracker()
    t.apply(event("agent.needs_input", at: "2026-09-30T14:05:00Z"))
    t.apply(event("agent.stopped", at: "2026-09-30T14:00:00Z"))
    #expect(t.current(now: iso("2026-09-30T14:06:00Z")).first?.needsInput != nil)
}

@Test func needsInputExpiresAfterEightHours() {
    var t = AgentTracker()
    t.apply(event("agent.needs_input", at: "2026-09-30T02:00:00Z"))
    #expect(t.current(now: iso("2026-09-30T09:59:00Z")).first?.needsInput != nil)
    #expect(t.current(now: iso("2026-09-30T10:01:00Z")).first?.needsInput == nil)
    #expect(t.current(now: iso("2026-10-01T02:01:00Z")).isEmpty)
}

@Test func nonAgentEventsAreIgnoredByTheTracker() {
    var t = AgentTracker()
    t.apply(Event(ts: .now, kind: "phase.done", repo: "/r", build: "1", phase: 1))
    #expect(t.sessions.isEmpty)
}

// MARK: - The board (reducer)

let now = iso("2026-09-30T14:02:00Z")

func fullBoard(agents: [AgentState] = [], sweep: SweepReport? = nil, error: RepoError? = nil) throws
    -> Board
{
    let repo = RepoSnapshot(
        path: "/Users/you/my-app", status: try Fixture.status("status-full.json"),
        statusAt: now, statusError: error, sweep: sweep, sweepAt: sweep == nil ? nil : now)
    return Board.make(repos: [repo], agents: agents, now: now)
}

@Test func needsYouHoldsGatesAndUnmergedOldestFirst() throws {
    let b = try fullBoard()
    #expect(b.needsYou.map(\.menuTitle) == ["172 not merged", "174 Plan gate"])
    #expect(b.inProgress.map(\.num) == ["173", "175"])  // most recent activity first
    #expect(b.menu == MenuBarState(title: "2 need you", attention: true, warning: false, busy: true))
    #expect(b.header == "4 builds · 2 need you")
}

@Test func cardShapes() throws {
    let b = try fullBoard()
    let c173 = try #require(b.inProgress.first { $0.num == "173" })
    #expect(c173.dots == [.done, .done, .done, .done, .active, .pending, .pending])
    #expect(c173.phaseLabel == "Implement")
    #expect(c173.startedAt == iso("2026-09-30T12:20:00Z"))
    let c175 = try #require(b.inProgress.first { $0.num == "175" })
    #expect(c175.dots == [.done, .active, .pending, .pending])  // fast lane: 1, 5, 6, 7
    let gate = try #require(b.needsYou.first { $0.card?.num == "174" })
    #expect(gate.card?.dots[3] == .waiting)
    #expect(gate.card?.phaseLabel == "Plan gate")
    #expect(gate.card?.url?.hasPrefix("http://build-174") == true)
}

@Test func menuShowsMostRecentBuildWhenNothingNeedsYou() {
    let rows = [
        BuildRow(
            num: "173", slug: "a", lastCommitAt: iso("2026-09-30T13:00:00Z"),
            phases: [PhaseInfo(n: 5, name: "Implement", status: "active")],
            tasks: TaskCount(done: 6, total: 11)),
        BuildRow(num: "175", slug: "b", lastCommitAt: iso("2026-09-30T12:00:00Z")),
    ]
    let b = Board.make(
        repos: [RepoSnapshot(path: "/r", status: StatusReport(builds: rows), statusAt: now)],
        agents: [], now: now)
    #expect(b.menu.title == "173 Implement 6/11 +1")
    #expect(!b.menu.attention)
}

@Test func idleBoard() {
    let b = Board.make(
        repos: [RepoSnapshot(path: "/r", status: StatusReport(builds: []), statusAt: now)],
        agents: [], now: now)
    #expect(b.menu == MenuBarState(title: nil, attention: false, warning: false))
    #expect(b.header == "Nothing in flight")
}

@Test func agentMatchesItsBuildByCheckoutRoot() throws {
    let agent = AgentState(
        session: "s", repo: "/Users/you/my-app",
        path: "/Users/you/my-app/.claude/worktrees/build-173/",
        lastEventAt: iso("2026-09-30T14:00:00Z"), lastKind: "agent.needs_input",
        needsInput: .init(since: iso("2026-09-30T14:00:00Z"), message: "Allow Bash?"))
    let b = try fullBoard(agents: [agent])
    let item = try #require(b.needsYou.first { if case .agent = $0.kind { true } else { false } })
    #expect(item.card?.num == "173")
    #expect(item.id == "agent-s")
    #expect(!b.inProgress.contains { $0.num == "173" })
}

/// Review: nested worktrees are separate checkouts, not part of the build in the main tree.
@Test func nestedWorktreeIsNotAttributedToTheMainCheckoutsBuild() {
    let row = BuildRow(
        num: "180", slug: "main_tree_build", branch: "build/180-x", lastCommitAt: now,
        worktree: "/Users/you/my-app")
    let agent = AgentState(
        session: "s", repo: "/Users/you/my-app",
        path: "/Users/you/my-app/.claude/worktrees/fix-typo", lastEventAt: now,
        lastKind: "agent.needs_input", needsInput: .init(since: now, message: nil))
    let b = Board.make(
        repos: [RepoSnapshot(path: "/Users/you/my-app", status: StatusReport(builds: [row]))],
        agents: [agent], now: now)
    #expect(b.needsYou.first?.card == nil)
    #expect(b.inProgress.map(\.num) == ["180"])
}

/// Review: an agent worktree branched from a build shows up as a second row with the same number.
@Test func duplicateRowsForOneBuildMergeAndStillMatchAgents() {
    let rows = [
        BuildRow(
            num: "174", slug: "checkout_flow", branch: "worktree-agent-1", lastCommitAt: now,
            worktree: "/r/.claude/worktrees/agent-1"),
        BuildRow(
            num: "174", slug: "checkout_flow", branch: "build/174-checkout-flow",
            state: "Phase 5 — Implement", lastCommitAt: now, worktree: "/r/.claude/worktrees/build-174"),
    ]
    let agent = AgentState(
        session: "s", repo: "/r", path: "/r/.claude/worktrees/agent-1", lastEventAt: now,
        lastKind: "agent.stopped")
    var claude = ClaudeSessions()
    claude.update(["s": .idle], at: now)
    let b = Board.make(
        repos: [RepoSnapshot(path: "/r", status: StatusReport(builds: rows))], agents: [agent], claude: claude,
        now: now)
    #expect(b.inProgress.count == 1)
    #expect(b.inProgress[0].worktree == "/r/.claude/worktrees/build-174")
    #expect(b.inProgress[0].agentLine != nil)
    #expect(b.buildCount == 1)
}

@Test func aParkedBuildsGateDoesNotNeedYou() {
    let row = BuildRow(
        num: "173", slug: "a", state: "Parked 2026-09-30", lastCommitAt: now,
        gates: [GateInfo(gate: "plan", status: "waiting", at: now)])
    let b = Board.make(
        repos: [RepoSnapshot(path: "/r", status: StatusReport(builds: [row]))], agents: [], now: now)
    #expect(b.needsYou.isEmpty)
    #expect(b.menu.title == nil)
}

@Test func activeClearsAPermissionPromptAndEndedForgetsTheSession() {
    var t = AgentTracker()
    t.apply(event("agent.needs_input", at: "2026-09-30T14:00:00Z"))
    t.apply(event("agent.active", at: "2026-09-30T14:00:30Z"))
    #expect(t.current(now: iso("2026-09-30T14:01:00Z")).first?.needsInput == nil)
    t.apply(event("agent.stopped", at: "2026-09-30T14:02:00Z"))
    t.apply(event("agent.needs_input", at: "2026-09-30T14:03:00Z"))  // idle prompt
    t.apply(event("agent.ended", at: "2026-09-30T14:05:00Z"))  // tab closed
    #expect(t.current(now: iso("2026-09-30T14:06:00Z")).isEmpty)
}

@Test func trackerSurvivesARelaunch() throws {
    var t = AgentTracker()
    t.apply(event("agent.needs_input", at: "2026-09-30T14:00:00Z", message: "waiting"))
    let restored = try JSONDecoder().decode(AgentTracker.self, from: JSONEncoder().encode(t))
    #expect(restored == t)
}

@Test func markerNamesAreSafe() {
    #expect(Paths.markerName("5c1e-ab_9") == "5c1e-ab_9")
    #expect(Paths.markerName("../../etc/passwd") == "etcpasswd")
    #expect(Paths.markerName("///") == "session")
}

@Test func agentActivityShowsOnTheCard() throws {
    let agent = AgentState(
        session: "s", repo: "/Users/you/my-app", path: "/Users/you/my-app/.claude/worktrees/build-173",
        lastEventAt: iso("2026-09-30T14:10:00Z"), lastKind: "agent.stopped", agent: "claude-code")
    let at = iso("2026-09-30T14:19:00Z")
    func line(_ claude: ClaudeSessions?) throws -> String? {
        let b = Board.make(
            repos: [RepoSnapshot(path: "/Users/you/my-app", status: try Fixture.status("status-full.json"))],
            agents: [agent], claude: claude, now: at)
        return try #require(b.inProgress.first { $0.num == "173" }).agentLine
    }
    // Without Claude Code's own status the card says nothing, even after a Stop.
    #expect(try line(nil) == nil)
    // A Stop with background agents still running: Claude Code says busy, and that wins.
    var claude = ClaudeSessions()
    claude.update(["s": .busy], at: iso("2026-09-30T14:00:00Z"))
    #expect(try line(claude) == "Claude working")
    // Seen going idle: how long is known.
    claude.update(["s": .idle], at: iso("2026-09-30T14:10:00Z"))
    #expect(try line(claude) == "Claude idle 9 min")
    // Idle at first sight: how long isn't.
    var fresh = ClaudeSessions()
    fresh.update(["s": .idle], at: at)
    #expect(try line(fresh) == "Claude idle")
    // A session Claude Code no longer lists has ended.
    claude.update([:], at: at)
    #expect(try line(claude) == nil)
}

@Test func claudeSessionsParseAndLocate() {
    let json = Data("""
        [{"pid":1,"sessionId":"a","status":"busy","cwd":"/r"},{"sessionId":"b","status":"idle"},
         {"sessionId":"c","status":"something-new"},{"status":"busy"}]
        """.utf8)
    #expect(ClaudeSessions.parse(json) == ["a": .busy, "b": .idle])
    #expect(ClaudeSessions.parse(Data("not json".utf8)) == nil)
    // An alias isn't on PATH; the usual install location is found instead.
    let found = ClaudeSessions.locate(path: "/usr/bin:/bin", home: "/Users/you") {
        $0 == "/Users/you/.claude/local/claude"
    }
    #expect(found == "/Users/you/.claude/local/claude")
    #expect(ClaudeSessions.locate(path: "/usr/bin", home: "/Users/you") { _ in false } == nil)
}

@Test func tasksShowOnlyOnceOneIsDone() {
    func card(_ done: Int) -> BuildCard? {
        let row = BuildRow(num: "1", slug: "a", lastCommitAt: now, tasks: TaskCount(done: done, total: 100))
        return Board.make(repos: [RepoSnapshot(path: "/r", status: StatusReport(builds: [row]))], agents: [], now: now)
            .inProgress.first
    }
    #expect(card(0)?.tasks == nil)  // a plan still being written isn't 0% done
    #expect(card(3)?.tasks == TaskCount(done: 3, total: 100))
}

@Test func agentOutsideAnyBuildStillNeedsYou() throws {
    let agent = AgentState(
        session: "s", repo: "/Users/me/other", path: "/Users/me/other", lastEventAt: now,
        lastKind: "agent.needs_input", needsInput: .init(since: now, message: nil), agent: "claude-code")
    let b = Board.make(repos: [], agents: [agent], now: now)
    #expect(b.needsYou.first?.menuTitle == "Claude waiting")
    #expect(b.needsYou.first?.repoName == "other")
}

@Test func leftBehindFromSweep() throws {
    let b = try fullBoard(sweep: try Fixture.sweep("sweep.json"))
    #expect(b.leftBehind.map(\.title) == [
        "1 leaked database", "2 processes in deleted folders", "1 stray route",
    ])
    #expect(b.leftCleanup == ["make clean-dbs", "portless prune"])
    #expect(b.leftBehind[1].command == "kill 67816 67818")
    #expect(b.leftBehind[1].details[0] == "pid 67816 · .claude/worktrees/129 (gone)")
    #expect(b.leftCount == 4)
    #expect(b.menu.warning)
}

@Test func staleRepoKeepsLastGoodDataAndReportsTheProblem() throws {
    let error = RepoError(message: "exit 1", since: now)
    let b = try fullBoard(error: error)
    #expect(b.problems.count == 1)
    #expect(b.inProgress.allSatisfy { $0.staleSince == now })
    #expect(b.header.hasSuffix("1 repo stale"))
    #expect(b.menu.warning)
    #expect(b.menu.unreadable)
    #expect(b.inProgress.allSatisfy { $0.tag == "stale" })
}

@Test func reposNotReadYetAreLoadingNotQuiet() {
    let b = Board.make(repos: [RepoSnapshot(path: "/r")], agents: [], now: now)
    #expect(b.loading == ["r"])
    #expect(b.header == "Checking…")
    #expect(b.menu.loading)
    // A failed first read is a problem, not loading.
    let failed = Board.make(
        repos: [RepoSnapshot(path: "/r", statusError: RepoError(message: "exit 1", since: now))], agents: [], now: now)
    #expect(failed.loading.isEmpty)
}

@Test func aFailedSweepIsShownUnderLeftBehind() {
    var repo = RepoSnapshot(path: "/r", status: StatusReport(builds: []), statusAt: now)
    repo.sweepError = RepoError(message: "sweep timed out after 20 s", since: now)
    let b = Board.make(repos: [repo], agents: [], now: now)
    #expect(b.leftNotes == ["r sweep failed · sweep timed out after 20 s"])
    #expect(!b.menu.unreadable)
}

@Test func leftBehindAloneIsAWarningButNotUnreadable() throws {
    let b = try fullBoard(sweep: SweepReport(processes: [.init(pid: 1, cwd: "/gone")]))
    #expect(b.menu.warning)
    #expect(!b.menu.unreadable)
}

// MARK: - Portable contract bits

@Test func anyGateNameAndExplicitPhaseSkipsAndParked() throws {
    let json = """
        {"v":1,"builds":[{"num":"12","slug":"x","branch":"feat/x","state":"In review","lastCommitAt":1790000000,
          "merged":false,"parked":false,
          "phases":[{"n":1,"name":"Draft","status":"done"},{"n":2,"name":"Design","status":"pending","skipped":true},
                    {"n":3,"name":"Review","status":"active"}],
          "gates":[{"gate":"design-review","status":"waiting","phase":3}]}]}
        """
    let s = try JSONDecoder().decode(StatusReport.self, from: Data(json.utf8))
    let b = Board.make(repos: [RepoSnapshot(path: "/r", status: s)], agents: [], now: now)
    let item = try #require(b.needsYou.first)
    #expect(item.menuTitle == "12 Design-review gate")
    #expect(item.card?.dots == [.done, .waiting])
    #expect(try Event.parse(
        Data(#"{"v":1,"kind":"gate.waiting","repo":"/r","build":"12","gate":"design-review"}"#.utf8),
        fallbackDate: now).gate == "design-review")
}

@Test func parkedFlagOverridesTheStatePrefix() {
    let row = BuildRow(num: "1", slug: "a", state: "Parked? no, busy", lastCommitAt: now, parked: false)
    #expect(!row.isParked)
    #expect(BuildRow(num: "2", slug: "b", lastCommitAt: now, parked: true).isParked)
}

@Test func duplicateEventsFromTwoEmittersCountOnce() {
    var t = AgentTracker()
    t.apply(event("agent.needs_input", at: "2026-09-30T14:00:00.000Z", message: "first"))
    t.apply(event("agent.needs_input", at: "2026-09-30T14:00:00.400Z", message: "second"))
    #expect(t.current(now: iso("2026-09-30T14:01:00Z")).first?.needsInput?.message == "first")
}

@Test func agentsAreNamedByTheirTool() {
    #expect(AgentState.displayName("claude-code") == "Claude")
    #expect(AgentState.displayName("codex") == "Codex")
    #expect(AgentState.displayName("aider") == "Aider")
    #expect(AgentState.displayName(nil) == "Agent")
}
