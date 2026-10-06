@testable import ChiefStewCore
import Foundation
import Testing

// A build's time budget on the board: the clock, who it's over budget for, and the one quiet
// notice that says so.

private let repo = "/Users/you/my-app"
private let start = iso("2026-10-03T10:00:00Z")

private func row(_ num: String, hours: Double?, parked: Bool = false, closed: Bool = false, mine: Bool? = nil) -> BuildRow {
    var r = BuildRow(
        num: num, slug: "b\(num)", state: parked ? "Parked" : "Phase 5", lastCommitAt: start,
        flags: closed ? ["closed-unmerged"] : [],
        phases: [PhaseInfo(n: 1, name: "Intent", status: "done", startedAt: start), PhaseInfo(n: 2, name: "Execute", status: "active")])
    r.budget = hours.map { Budget(hours: $0, label: "L") }
    r.mine = mine
    return r
}

private func board(_ rows: [BuildRow], at now: Date) -> Board {
    Board.make(repos: [RepoSnapshot(path: repo, status: StatusReport(builds: rows), statusAt: now)], agents: [], now: now)
}

@Test func overBudgetIsYourOpenBuildsPastTheirBudget() {
    let now = start.addingTimeInterval(2.5 * 3600)
    let b = board([
        row("001", hours: 2),  // over (authorship unknown counts as yours)
        row("002", hours: 4),  // within
        row("003", hours: 2, parked: true),  // parked: no clock
        row("004", hours: 2, closed: true),  // closed: its clock has stopped
        row("005", hours: 2, mine: false),  // a teammate's: not yours to be told about
        row("006", hours: nil),  // no budget
    ], at: now)
    #expect(b.overBudget.map(\.num) == ["001"])
    let within = b.inProgress.first { $0.num == "002" }
    #expect(within?.budgetClock(now: now)?.elapsed == 2.5 * 3600)
    #expect(b.inProgress.first { $0.num == "003" }?.budgetClock(now: now) == nil)
}

@Test func overBudgetSendsOneQuietNoticeAndWithdrawsItWhenTheBuildIsDone() {
    let now = start.addingTimeInterval(2.5 * 3600)
    let over = board([row("001", hours: 2)], at: now)
    let first = NotificationPlanner.plan(board: over, ledger: NoticeLedger(), settings: Preferences(), now: now, loaded: [repo])
    #expect(first.post.count == 1)
    let notice = first.post[0]
    #expect(notice.passive && !notice.isReminder)
    #expect(notice.title == "001 is over its budget")
    #expect(notice.body == "b001 has run 2h 30m (budget L, 2h). Worth noting why while it's fresh.")

    // Still over an hour later: nothing new.
    let later = now.addingTimeInterval(3600)
    let again = NotificationPlanner.plan(board: board([row("001", hours: 2)], at: later), ledger: first.ledger, settings: Preferences(), now: later, loaded: [repo])
    #expect(again.post.isEmpty && again.withdraw.isEmpty)

    // Closed: the notice goes.
    let done = NotificationPlanner.plan(board: board([row("001", hours: 2, closed: true)], at: later), ledger: first.ledger, settings: Preferences(), now: later, loaded: [repo])
    #expect(done.withdraw == [notice.id])

    // Turned off: nothing.
    var off = Preferences()
    off.notifyBudget = false
    #expect(NotificationPlanner.plan(board: over, ledger: NoticeLedger(), settings: off, now: now, loaded: [repo]).post.isEmpty)
}

/// A start written as a day is midnight to the parser, not when it began: it's shown as the day,
/// survives `chiefstew status` as a day, and never times a budget.
@Test func aStartKnownOnlyByItsDayIsShownAsTheDay() throws {
    #expect(LooseDate.isDateOnly("2026-10-06"))
    #expect(!LooseDate.isDateOnly("2026-10-06 09:10"))
    #expect(!LooseDate.isDateOnly("2026-10-06T09:10:00Z"))

    let phases = WorkflowEngine.phases(
        "- [ ] 1. Draft (started 2026-10-06)\n- [ ] 2. Build (started 2026-10-06 09:10)\n",
        .regex("^- \\[(?<done>[ x])\\] (?<n>\\d)\\. (?<name>\\w+) \\(started (?<started>[\\d: -]+)\\)$"))
    #expect(phases.map(\.startedDateOnly) == [true, false])

    var row = BuildRow(num: "012", slug: "a", lastCommitAt: Date(), phases: phases)
    row.budget = Budget(hours: 1)
    let json = try JSONSerialization.data(withJSONObject: StatusJSON.encode(StatusReport(builds: [row])))
    let back = try JSONDecoder().decode(StatusReport.self, from: json)
    #expect(back.builds[0].phases?.map(\.startedDateOnly) == [true, false])

    let now = try #require(LooseDate.parse("2026-10-06 23:00"))
    let card = try #require(
        Board.make(repos: [RepoSnapshot(path: "/r", status: back)], agents: [], now: now).inProgress.first)
    #expect(card.startedDateOnly)
    #expect(card.budgetClock(now: now) == nil)
    #expect(Durations.sinceDay(card.startedAt!, now: now, locale: Locale(identifier: "en_GB")) == "since 6 Oct")
    let nextYear = now.addingTimeInterval(400 * 86400)
    #expect(Durations.sinceDay(card.startedAt!, now: nextYear, locale: Locale(identifier: "en_GB")) == "since 6 Oct 2026")
}

/// The dots' tooltip says what each dot is and when: two phases under way are told apart, a
/// finished one has its span, a day-only start stays a day, and a waiting gate says so.
@Test func phaseLinesNameAndTimeEveryDot() throws {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = .current
    let at = { (s: String) in LooseDate.parse(s)! }
    var p1 = PhaseInfo(n: 1, name: "Corpus review", status: "done", startedAt: at("2026-10-06"), doneAt: at("2026-10-06 19:50"))
    p1.startedDateOnly = true
    let rows = [
        p1,
        PhaseInfo(n: 2, name: "Research", status: "active", startedAt: at("2026-10-06 19:50")),
        PhaseInfo(n: 3, name: "Proposal", status: "done", startedAt: at("2026-10-06 19:58"), doneAt: at("2026-10-06 20:03")),
        PhaseInfo(n: 4, name: "Challenge", status: "active", startedAt: at("2026-10-06 20:03")),
        PhaseInfo(n: 5, name: "Accept", status: "pending"),
    ]
    let row = BuildRow(
        num: "R03", slug: "", lastCommitAt: Date(), phases: rows,
        gates: [GateInfo(gate: "sign-off", status: "waiting", phase: 4)])
    let now = at("2026-10-06 20:55")
    let card = try #require(
        Board.make(repos: [RepoSnapshot(path: "/r", status: StatusReport(builds: [row]))], agents: [], now: now)
            .needsYou.first?.card)
    #expect(card.phaseLines(now: now, calendar: cal, locale: Locale(identifier: "en_GB")) == [
        "✓ Corpus review · 6 Oct → 19:50",
        "◐ Research · since 19:50 (1h 5m)",
        "✓ Proposal · 19:58 → 20:03 (5 min)",
        "● Challenge · since 20:03 (52 min) · waiting on sign-off",
        "○ Accept",
    ])
    // On hover, one phase replaces the label: no mark, since the dot under the pointer is one.
    #expect(card.phaseLine(1, now: now)?.hasPrefix("Research · since ") == true)
    #expect(card.phaseLine(4, now: now) == "Accept")
    #expect(card.phaseLine(5, now: now) == nil)
}
