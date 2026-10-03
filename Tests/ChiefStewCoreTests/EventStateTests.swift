@testable import ChiefStewCore
import Foundation
import Testing

// MARK: - Events as the source of state (contract § 3.3, § 3.4)

@Test func aCopyWithTheSameIDIsAppliedOnce() {
    var state = EventState()
    var ask = event("agent.needs_input", at: "2026-09-30T14:00:00Z", message: "permission")
    ask.id = "e1"
    var answer = event("agent.active", at: "2026-09-30T14:00:30Z")
    answer.id = "e2"
    let first = state.apply(ask), second = state.apply(answer)
    let copy = state.apply(ask)  // a late copy of the question doesn't re-open it
    #expect(first && second && !copy)
    #expect(state.agents.current(now: iso("2026-09-30T14:01:00Z")).first?.needsInput == nil)
}

@Test func theEmitterGivesEveryEventAnID() throws {
    let home = try tempDir()
    let paths = Paths(environment: ["CHIEFSTEW_HOME": home.path])
    try FileManager.default.createDirectory(at: paths.inbox, withIntermediateDirectories: true)
    Emitter.emit(["kind": "agent.stopped", "repo": "/r", "session": "s"], paths: paths)
    Emitter.emit(["kind": "agent.stopped", "repo": "/r", "session": "s"], paths: paths)
    let ids = InboxReader.drain(paths.inbox).events.compactMap(\.id)
    #expect(ids.count == 2 && Set(ids).count == 2)
}

@Test func eventGatesOpenAndClose() {
    var g = EventGates()
    let t = iso("2026-09-30T14:00:00Z")
    g.apply(Event(ts: t, kind: "gate.waiting", repo: "/r/", build: "012", gate: "plan"))
    g.apply(Event(ts: t + 60, kind: "gate.waiting", repo: "/r", build: "012", gate: "plan"))  // a reminder
    g.apply(Event(ts: t, kind: "gate.waiting", repo: "/r", build: "013", gate: "review"))
    #expect(g.current(now: t + 120).map(\.build) == ["012", "013"])
    #expect(g.current(now: t + 120).first?.since == t)  // the first wait's start
    g.apply(Event(ts: t + 180, kind: "gate.approved", repo: "/r", build: "012", gate: "plan"))
    g.apply(Event(ts: t + 180, kind: "build.closed", repo: "/r", build: "013"))
    #expect(g.current(now: t + 200).isEmpty)
    g.apply(Event(ts: t, kind: "gate.waiting", repo: "/r", build: "014", gate: "plan"))
    #expect(g.current(now: t + 25 * 3600).isEmpty)  // forgotten after a day
}

@Test func eventGatesShowOnlyWhereStatusCantShowThem() {
    let t = iso("2026-09-30T14:00:00Z")
    let wait = EventGates.Wait(repo: "/Users/you/my-app", build: "012", gate: "plan", slug: "thing", since: t)
    func board(_ snapshot: RepoSnapshot?) -> Board {
        Board.make(repos: snapshot.map { [$0] } ?? [], agents: [], eventGates: [wait], now: t + 60)
    }
    #expect(board(nil).needsYou.first?.menuTitle == "012 Plan gate")  // not registered
    #expect(board(RepoSnapshot(path: "/Users/you/my-app")).needsYou.count == 1)  // not read yet
    let loaded = RepoSnapshot(path: "/Users/you/my-app", status: StatusReport(builds: []))
    #expect(board(loaded).needsYou.isEmpty)  // status is the truth once it's read
    var failing = loaded
    failing.statusError = RepoError(message: "boom", since: t)
    #expect(board(failing).needsYou.count == 1)
}

@Test func theJournalReplaysToTheSameState() throws {
    let home = try tempDir()
    let journal = EventJournal(paths: Paths(environment: ["CHIEFSTEW_HOME": home.path]))
    var ask = event("agent.needs_input", at: "2026-09-30T14:00:00Z", worktree: "/Users/you/my-app/wt", message: "permission")
    ask.id = "e1"
    ask.notificationType = "permission_prompt"
    ask.hostApp = "com.example.term"
    ask.hostPid = 42
    ask.tty = "ttys001"
    let gate = Event(ts: iso("2026-09-30T14:01:00Z"), kind: "gate.waiting", repo: "/Users/you/my-app", build: "012", gate: "plan")
    journal.append([ask])
    journal.append([gate])

    var live = EventState()
    live.apply(ask)
    live.apply(gate)
    var replayed = EventState()
    for e in journal.replay(now: iso("2026-09-30T15:00:00Z")) { replayed.apply(e) }
    #expect(replayed == live)
    #expect(journal.replay(now: iso("2026-10-02T15:00:00Z")).isEmpty)  // older than a day
}

@Test func theJournalRotates() throws {
    let home = try tempDir()
    let journal = EventJournal(paths: Paths(environment: ["CHIEFSTEW_HOME": home.path]))
    let e = event("agent.stopped", at: "2026-09-30T14:00:00Z")
    journal.append([e])
    // Push the current file over the limit; the next append moves it aside.
    let handle = try FileHandle(forWritingTo: journal.url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(repeating: 0x20, count: EventJournal.maxBytes))
    try handle.close()
    journal.append([e])
    #expect(FileManager.default.fileExists(atPath: journal.previous.path))
    #expect(journal.replay(now: iso("2026-09-30T15:00:00Z")).count == 2)  // both files are read
}
