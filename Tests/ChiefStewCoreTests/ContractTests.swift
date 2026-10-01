@testable import ChiefStewCore
import Foundation
import Testing

// MARK: - Events (contract § 3)

@Test func parsesAFullEvent() throws {
    let json = """
        {"v":1,"ts":"2026-09-30T14:02:11.123Z","kind":"gate.waiting","repo":"/r","build":"174",
         "gate":"Plan","phase":4,"lane":"full","extra":"ignored"}
        """
    let e = try Event.parse(Data(json.utf8), fallbackDate: .distantPast)
    #expect(e.kind == "gate.waiting")
    #expect(e.gate == "plan")
    #expect(e.phase == 4)
    #expect(e.ts == iso("2026-09-30T14:02:11.123Z"))
}

@Test func badTimestampFallsBackToMtime() throws {
    let mtime = iso("2026-09-30T10:00:00Z")
    let e = try Event.parse(
        Data(#"{"v":1,"ts":"yesterday","kind":"agent.stopped","repo":"/r","session":"s"}"#.utf8),
        fallbackDate: mtime)
    #expect(e.ts == mtime)
}

@Test func unknownKindsParseSoTheContractCanGrow() throws {
    let e = try Event.parse(Data(#"{"v":1,"kind":"future.thing","repo":"/r"}"#.utf8), fallbackDate: .now)
    #expect(e.kind == "future.thing")
}

@Test func messageIsTruncated() throws {
    let long = String(repeating: "x", count: 500)
    let e = try Event.parse(
        Data(#"{"v":1,"kind":"agent.needs_input","repo":"/r","session":"s","message":"\#(long)"}"#.utf8),
        fallbackDate: .now)
    #expect(e.message?.count == 200)
}

@Test(arguments: [
    (#"not json"#, EventError.notJSON),
    (#"[1,2]"#, EventError.notJSON),
    (#"{"v":2,"kind":"phase.done","repo":"/r"}"#, EventError.wrongVersion(2)),
    (#"{"kind":"phase.done","repo":"/r"}"#, EventError.wrongVersion(nil)),
    (#"{"v":1,"repo":"/r"}"#, EventError.missing("kind")),
    (#"{"v":1,"kind":"phase.done"}"#, EventError.missing("repo")),
    (#"{"v":1,"kind":"phase.done","repo":"/r","build":"1"}"#, EventError.missing("phase")),
    (#"{"v":1,"kind":"phase.done","repo":"/r","build":"1","phase":9}"#, EventError.missing("phase")),
    (#"{"v":1,"kind":"gate.waiting","repo":"/r","build":"1","gate":"Not Valid!"}"#, EventError.missing("gate")),
    (#"{"v":1,"kind":"agent.stopped","repo":"/r"}"#, EventError.missing("session")),
])
func rejectsMalformedEvents(json: String, expected: EventError) {
    #expect(throws: expected) { try Event.parse(Data(json.utf8), fallbackDate: .now) }
}

@Test func rejectsOversizedEvents() {
    let big = Data(repeating: 0x20, count: Event.maxBytes + 1)
    #expect(throws: EventError.tooLarge(Event.maxBytes + 1)) {
        try Event.parse(big, fallbackDate: .now)
    }
}

// MARK: - status --json / sweep --json (contract § 4–5)

@Test func decodesFullStatusAndSkipsABadRow() throws {
    let s = try Fixture.status("status-full.json")
    #expect(s.builds.map(\.num) == ["174", "173", "175", "172"])
    #expect(s.skippedRows == 1)
    let b174 = s.builds[0]
    #expect(b174.waitingGates.map(\.gate) == ["plan"])
    #expect(b174.gates[0].at != nil)  // date-only still parses
    #expect(b174.tasks == TaskCount(done: 0, total: 9))
    #expect(b174.phases?.count == 7)
    let b175 = s.builds[2]
    #expect(b175.lane == "fast")
    #expect(b175.worktree == nil)
    #expect(b175.lastCommitAt == Date(timeIntervalSince1970: 1_759_239_000))  // unix seconds
    #expect(s.builds[1].phases?[4].startedAt == LooseDate.parse("2026-09-30 13:10"))  // raw stamp
}

@Test func badOptionalFieldsBecomeNil() throws {
    let s = try Fixture.status("status-minimal.json")
    #expect(s.builds.count == 1)
    #expect(s.builds[0].phases == nil)
    #expect(s.builds[0].tasks == nil)
}

@Test func wrongStatusVersionFails() {
    #expect(throws: (any Error).self) { try Fixture.status("status-v2.json") }
}

@Test func decodesSweep() throws {
    let s = try Fixture.sweep("sweep.json")
    #expect(s.databases?.leaked == ["myapp_wt_fix_b"])
    #expect(s.processes.map(\.pid) == [67816, 67818])
    #expect(s.routes.first?.reason == "process 5512 is gone")
    let down = try Fixture.sweep("sweep-docker-down.json")
    #expect(down.databases?.checked == false)
    #expect(down.errors.count == 1)
}

// MARK: - Dates

@Test func looseDates() {
    #expect(LooseDate.parse("2026-09-30T14:02:11Z") != nil)
    #expect(LooseDate.parse("2026-09-30T14:02:11.5Z") != nil)
    #expect(LooseDate.parse("2026-09-30T09:12:00+01:00") == LooseDate.parse("2026-09-30T08:12:00Z"))
    #expect(LooseDate.parse("2026-09-30") != nil)
    #expect(LooseDate.parse("2026-09-30 13:10") != nil)
    #expect(LooseDate.parse("soon") == nil)
}

@Test func durations() {
    #expect(Durations.short(30) == "just now")
    #expect(Durations.short(12 * 60) == "12 min")
    #expect(Durations.short(102 * 60) == "1h 42m")
    #expect(Durations.short(2 * 86400 + 5) == "2 d")
    #expect(Durations.ago(180) == "3 min ago")
}

// MARK: - Parked builds

@Test func parkedBuildIsDimmedAndOffTheMenuBar() {
    let row = BuildRow(
        num: "173", slug: "search_index", state: "Parked 2026-09-30, waiting on a decision",
        lastCommitAt: iso("2026-09-30T17:09:32Z"),
        phases: [PhaseInfo(n: 1, name: "Brief", status: "active"), PhaseInfo(n: 2, name: "Design", status: "pending")])
    let board = Board.make(
        repos: [RepoSnapshot(path: "/Users/you/my-app", status: StatusReport(builds: [row]))], agents: [],
        now: iso("2026-09-30T18:13:00Z"))
    #expect(board.inProgress.first?.parked == true)
    #expect(board.menu == MenuBarState(title: nil, attention: false, warning: false))
    #expect(board.header == "1 parked")
}

@Test func parkedSortsLastAndIsSkippedForTheTitle() {
    let rows = [
        BuildRow(num: "173", slug: "a", state: "Parked 2026-09-30", lastCommitAt: iso("2026-09-30T14:00:00Z")),
        BuildRow(
            num: "175", slug: "b", lastCommitAt: iso("2026-09-30T12:00:00Z"),
            phases: [PhaseInfo(n: 5, name: "Implement", status: "active")]),
    ]
    let b = Board.make(
        repos: [RepoSnapshot(path: "/r", status: StatusReport(builds: rows))], agents: [],
        now: iso("2026-09-30T14:02:00Z"))
    #expect(b.inProgress.map(\.num) == ["175", "173"])
    #expect(b.menu.title == "175 Implement")
    #expect(b.header == "1 build · 1 parked")
}
