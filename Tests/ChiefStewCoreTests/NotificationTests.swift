@testable import ChiefStewCore
import Foundation
import Testing

private let t0 = iso("2026-09-30T14:00:00Z")

private func gateBoard(since: Date = t0, at now: Date = t0) -> Board {
    let row = BuildRow(
        num: "174", slug: "checkout_flow", lastCommitAt: since, worktree: "/wt/174",
        gates: [
            GateInfo(gate: "plan", status: "waiting", at: since, artefact: "/wt/174/plan.md")
        ])
    return Board.make(
        repos: [RepoSnapshot(path: "/r", status: StatusReport(builds: [row]))], agents: [],
        now: now)
}

@Test func firstSightNotifiesOnce() {
    var ledger = NoticeLedger()
    let first = NotificationPlanner.plan(
        board: gateBoard(), ledger: ledger, settings: Preferences(), now: t0, loaded: ["/r"])
    #expect(first.post.map(\.title) == ["174 needs you"])
    #expect(first.post[0].body == "Plan gate · checkout_flow")
    #expect(first.post[0].open == "/wt/174/plan.md")
    ledger = first.ledger
    let again = NotificationPlanner.plan(
        board: gateBoard(at: t0 + 60), ledger: ledger, settings: Preferences(), now: t0 + 60,
        loaded: ["/r"])
    #expect(again.post.isEmpty)
}

@Test func gateRemindsOnTheIntervalWithTheSameID() {
    let first = NotificationPlanner.plan(
        board: gateBoard(), ledger: NoticeLedger(), settings: Preferences(), now: t0, loaded: ["/r"])
    let later = t0 + 30 * 60
    let reminder = NotificationPlanner.plan(
        board: gateBoard(at: later), ledger: first.ledger, settings: Preferences(), now: later,
        loaded: ["/r"])
    #expect(reminder.post.count == 1)
    #expect(reminder.post[0].isReminder)
    #expect(reminder.post[0].id == first.post[0].id)
    #expect(reminder.post[0].body == "Plan gate · checkout_flow · waiting 30 min")
}

@Test func remindersCanBeTurnedOff() {
    var settings = Preferences()
    settings.reminderMinutes = 0
    let first = NotificationPlanner.plan(
        board: gateBoard(), ledger: NoticeLedger(), settings: settings, now: t0, loaded: ["/r"])
    let later = t0 + 5 * 3600
    let plan = NotificationPlanner.plan(
        board: gateBoard(at: later), ledger: first.ledger, settings: settings, now: later,
        loaded: ["/r"])
    #expect(plan.post.isEmpty)
}

@Test func resolvedItemsAreWithdrawnButOnlyOnceEveryRepoHasReported() {
    let first = NotificationPlanner.plan(
        board: gateBoard(), ledger: NoticeLedger(), settings: Preferences(), now: t0, loaded: ["/r"])
    let empty = Board()
    let loading = NotificationPlanner.plan(
        board: empty, ledger: first.ledger, settings: Preferences(), now: t0 + 5, loaded: [])
    #expect(loading.withdraw.isEmpty)
    #expect(loading.ledger == first.ledger)
    let resolved = NotificationPlanner.plan(
        board: empty, ledger: first.ledger, settings: Preferences(), now: t0 + 5, loaded: ["/r"])
    #expect(resolved.withdraw == [first.post[0].id])
    #expect(resolved.ledger.sent.isEmpty)
}

@Test func aReopenedGateIsANewWait() {
    let first = NotificationPlanner.plan(
        board: gateBoard(), ledger: NoticeLedger(), settings: Preferences(), now: t0, loaded: ["/r"])
    let reopened = t0 + 3600
    let plan = NotificationPlanner.plan(
        board: gateBoard(since: reopened, at: reopened), ledger: first.ledger,
        settings: Preferences(), now: reopened, loaded: ["/r"])
    #expect(plan.post.count == 1 && !plan.post[0].isReminder)
    #expect(plan.withdraw == [first.post[0].id])
}

@Test func agentsNotifyOnceAndNeverRemind() {
    let agent = AgentState(
        session: "s", repo: "/r", path: "/elsewhere", lastEventAt: t0,
        lastKind: "agent.needs_input", needsInput: .init(since: t0, message: "Allow Bash?"),
        agent: "claude-code")
    let board = Board.make(repos: [], agents: [agent], now: t0)
    let first = NotificationPlanner.plan(
        board: board, ledger: NoticeLedger(), settings: Preferences(), now: t0, loaded: ["/r"])
    #expect(first.post.map(\.title) == ["Claude needs you"])
    #expect(first.post[0].body == "Allow Bash? · elsewhere")
    let later = t0 + 3 * 3600
    let again = NotificationPlanner.plan(
        board: Board.make(repos: [], agents: [agent], now: later), ledger: first.ledger,
        settings: Preferences(), now: later, loaded: ["/r"])
    #expect(again.post.isEmpty)
}

@Test func kindsCanBeSwitchedOff() {
    var settings = Preferences()
    settings.notifyGates = false
    let plan = NotificationPlanner.plan(
        board: gateBoard(), ledger: NoticeLedger(), settings: settings, now: t0, loaded: ["/r"])
    #expect(plan.post.isEmpty)
}

@Test func settingsDecodeLeniently() throws {
    let s = try JSONDecoder().decode(Preferences.self, from: Data(#"{"reminderMinutes":15,"notifyAgents":"nope"}"#.utf8))
    #expect(s.reminderMinutes == 15)
    #expect(s.notifyAgents)  // bad value → default
    #expect(s.notifyGates)
    #expect(s.worktreeApp == nil)
}

@Test func buildNoticesAreOnlyWithdrawnOnceTheirRepoHasLoaded() {
    let first = NotificationPlanner.plan(
        board: gateBoard(), ledger: NoticeLedger(), settings: Preferences(), now: t0, loaded: ["/r"])
    // Relaunch, and /r's first status call fails: nothing is on the board for it.
    let failing = NotificationPlanner.plan(
        board: Board(), ledger: first.ledger, settings: Preferences(), now: t0 + 60, loaded: [])
    #expect(failing.withdraw.isEmpty)
    #expect(failing.ledger == first.ledger)
    // Status recovers with the same wait: no second notification.
    let recovered = NotificationPlanner.plan(
        board: gateBoard(at: t0 + 120), ledger: failing.ledger, settings: Preferences(),
        now: t0 + 120, loaded: ["/r"])
    #expect(recovered.post.isEmpty)
}

@Test func agentNoticesAreWithdrawnEvenBeforeReposLoad() {
    var ledger = NoticeLedger()
    ledger.sent["agent-s@1790000000"] = t0
    let plan = NotificationPlanner.plan(
        board: Board(), ledger: ledger, settings: Preferences(), now: t0, loaded: [])
    #expect(plan.withdraw == ["agent-s@1790000000"])
}

@Test func gatesFromEventsNotifyForUnregisteredReposAndWithdrawWhenApproved() {
    var state = EventState()
    state.apply(
        Event(ts: t0, kind: "gate.waiting", repo: "/Users/me/other", build: "012", slug: "thing", gate: "plan"))
    let board = Board.make(repos: [], agents: [], eventGates: state.gates.current(now: t0), now: t0)
    let plan = NotificationPlanner.plan(
        board: board, ledger: NoticeLedger(), settings: Preferences(), now: t0, loaded: [], registered: [])
    let notice = try! #require(plan.post.first)
    #expect(notice.title == "012 needs you")
    #expect(notice.body == "Plan gate · thing")
    #expect(notice.open == nil)

    state.apply(Event(ts: t0 + 60, kind: "gate.approved", repo: "/Users/me/other", build: "012", gate: "plan"))
    let after = Board.make(repos: [], agents: [], eventGates: state.gates.current(now: t0 + 60), now: t0 + 60)
    let next = NotificationPlanner.plan(
        board: after, ledger: plan.ledger, settings: Preferences(), now: t0 + 60, loaded: [], registered: [])
    #expect(next.withdraw == [notice.id])
}

@Test func aGateWithNoSlugNamesItsRepo() {
    var state = EventState()
    state.apply(Event(ts: t0, kind: "gate.waiting", repo: "/Users/me/other", build: "012", gate: "plan"))
    let board = Board.make(repos: [], agents: [], eventGates: state.gates.current(now: t0), now: t0)
    let plan = NotificationPlanner.plan(
        board: board, ledger: NoticeLedger(), settings: Preferences(), now: t0, loaded: [], registered: [])
    #expect(plan.post.first?.body == "Plan gate · other")
}
