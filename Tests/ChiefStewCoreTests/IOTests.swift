@testable import ChiefStewCore
import Foundation
import Testing

// MARK: - Inbox (contract § 2, § 3.4)

@Test func drainReadsSortsDeletesAndRejects() throws {
    let dir = try tempDir()
    func write(_ name: String, _ text: String) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }
    let recent = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-60))
    let older = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-120))
    try write("2-b.json", #"{"v":1,"ts":"\#(recent)","kind":"agent.stopped","repo":"/r","session":"s"}"#)
    try write("1-a.json", #"{"v":1,"ts":"\#(older)","kind":"agent.needs_input","repo":"/r","session":"s"}"#)
    try write("3-bad.json", "{nope")
    try write("4-old.json", #"{"v":1,"ts":"2020-01-01T00:00:00Z","kind":"phase.done","repo":"/r","build":"1","phase":1}"#)
    try write(".5-inflight.json.tmp", "{}")
    try write("notes.txt", "ignored")

    let r = InboxReader.drain(dir)
    #expect(r.events.map(\.kind) == ["agent.needs_input", "agent.stopped"])
    #expect(r.rejected.map(\.file) == ["3-bad.json"])
    #expect(r.expired == 1)
    let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    #expect(left == [".5-inflight.json.tmp", "notes.txt"])
}

@Test func drainOfAMissingFolderIsEmpty() {
    let r = InboxReader.drain(URL(fileURLWithPath: "/nonexistent/chiefstew/inbox"))
    #expect(r.events.isEmpty && r.rejected.isEmpty)
}

@Test func watcherFiresOnANewFile() async throws {
    let dir = try tempDir()
    let fired = AsyncStream.makeStream(of: Void.self)
    let watcher = InboxWatcher(dir: dir) { fired.continuation.yield() }
    watcher.ensureRunning()
    try await Task.sleep(for: .milliseconds(100))
    let tmp = dir.appendingPathComponent(".x.tmp")
    try Data("{}".utf8).write(to: tmp)
    try FileManager.default.moveItem(at: tmp, to: dir.appendingPathComponent("x.json"))
    let got = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in fired.stream { return true }
            return false
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(3))
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
    watcher.stop()
    #expect(got)
}

// MARK: - Commands and the status client (contract § 6)

@Test func runnerCapturesOutputAndExitCode() async throws {
    let r = try await CommandRunner.run(
        "/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], timeout: 5)
    #expect(String(decoding: r.stdout, as: UTF8.self) == "out\n")
    #expect(r.stderrText == "err")
    #expect(r.exitCode == 3)
    #expect(!r.timedOut)
}

@Test func runnerTimesOut() async throws {
    let start = Date()
    let r = try await CommandRunner.run("/bin/sleep", ["10"], timeout: 0.5)
    #expect(r.timedOut)
    #expect(Date().timeIntervalSince(start) < 5)
}

@Test func runnerHandlesLargeOutput() async throws {
    let r = try await CommandRunner.run(
        "/bin/sh", ["-c", "head -c 300000 /dev/zero; head -c 200000 /dev/zero >&2"], timeout: 10)
    #expect(r.stdout.count == 300_000)
    #expect(r.stderr.count == 200_000)
}

@Test func nodeMajorVersion() {
    #expect(LoginEnvironment.majorVersion("v24.21.0") == 24)  // kept for display/diagnostics
    #expect(LoginEnvironment.majorVersion("v9.1.0") == 9)
    #expect(LoginEnvironment.majorVersion("") == nil)
}

/// A fake repo whose "node" is a shell script that prints a fixture or fails, like the plan's
/// "fake status command" integration test.
func fakeRepo(stdout: String, exit: Int = 0) throws -> (repo: String, client: StatusClient) {
    let dir = try tempDir()
    try FileManager.default.createDirectory(
        at: dir.appendingPathComponent("scripts"), withIntermediateDirectories: true)
    try Data().write(to: dir.appendingPathComponent("scripts/status.mjs"))
    try Data(#"{ "v": 1, "status": ["node", "scripts/status.mjs"], "sweep": ["node", "scripts/status.mjs", "sweep"] }"#.utf8)
        .write(to: dir.appendingPathComponent(".chiefstew.json"))
    let out = dir.appendingPathComponent("out.txt")
    try Data(stdout.utf8).write(to: out)
    let node = dir.appendingPathComponent("fake-node")
    let script = """
        #!/bin/sh
        # Record the arguments so tests can check them, then print the canned output.
        echo "$@" > "\(dir.path)/args.txt"
        env > "\(dir.path)/env.txt"
        cat "\(out.path)"
        [ \(exit) -ne 0 ] && echo "boom" >&2
        exit \(exit)
        """
    try Data(script.utf8).write(to: node)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: node.path)
    let login = LoginEnvironment(node: node.path, path: "/usr/bin:/bin", nodeVersion: "v24.0.0")
    return (dir.path, StatusClient(login: login, base: ["HOME": "/tmp"]))
}

@Test func statusRunsReadOnlyAndDecodes() async throws {
    let json = String(decoding: try Fixture.data("status-full.json"), as: UTF8.self)
    let (repo, client) = try fakeRepo(stdout: json)
    let result = await client.status(repo: repo)
    #expect(try result.get()?.builds.count == 4)
    let args = try String(contentsOfFile: repo + "/args.txt", encoding: .utf8)
    #expect(args == "scripts/status.mjs\n")
    let env = try String(contentsOfFile: repo + "/env.txt", encoding: .utf8)
    #expect(env.contains("GIT_OPTIONAL_LOCKS=0"))
    #expect(env.contains("NO_COLOR=1"))
}

@Test func textOutputMeansTheCommandIsNotTheContract() async throws {
    let (repo, client) = try fakeRepo(stdout: "173 search_index\n    branch …")
    let result = await client.status(repo: repo)
    guard case .failure(.noJSONSupport) = result else {
        Issue.record("expected noJSONSupport, got \(result)")
        return
    }
}

@Test func failureCarriesTheLastStderrLine() async throws {
    let (repo, client) = try fakeRepo(stdout: "", exit: 1)
    let result = await client.status(repo: repo)
    guard case .failure(let e) = result else {
        Issue.record("expected failure")
        return
    }
    #expect(e.description.hasSuffix("exit 1 · “boom”"))
}

@Test func missingRepoIsAnErrorNotAHang() async {
    let client = StatusClient(node: "/bin/echo", environment: [:])
    let result = await client.status(repo: "/nonexistent/repo")
    #expect(result == .failure(.repoMissing("/nonexistent/repo")))
}

@Test func sweepDecodes() async throws {
    let json = String(decoding: try Fixture.data("sweep.json"), as: UTF8.self)
    let (repo, client) = try fakeRepo(stdout: json)
    #expect(try await client.sweep(repo: repo).get()?.processes.count == 2)
    let args = try String(contentsOfFile: repo + "/args.txt", encoding: .utf8)
    #expect(args == "scripts/status.mjs sweep\n")
}

/// The hook path end to end: events written by the Emitter (as `chiefstew hook` does) are
/// drained and drive the tracker like the app does.
@Test func emittedHookEventsParseAndDrive() throws {
    let home = try tempDir()
    let paths = Paths(environment: ["CHIEFSTEW_HOME": home.path])
    try FileManager.default.createDirectory(at: paths.inbox, withIntermediateDirectories: true)
    let base: [String: Any] = ["repo": "/Users/you/my-app", "worktree": "/Users/you/my-app/.claude/worktrees/x", "agent": "claude-code"]
    let now = Date()
    for (i, (kind, session)) in [("agent.needs_input", "a"), ("agent.stopped", "b"), ("agent.resumed", "c")].enumerated() {
        var e = base
        e["kind"] = kind
        e["session"] = session
        if kind == "agent.needs_input" { e["notification_type"] = "permission_prompt" }
        Emitter.emit(e, paths: paths, now: now.addingTimeInterval(Double(i)))
    }
    let r = InboxReader.drain(paths.inbox)
    #expect(r.rejected.isEmpty)
    #expect(r.events.map(\.kind) == ["agent.needs_input", "agent.stopped", "agent.resumed"])
    #expect(r.events[0].notificationType == "permission_prompt")
    var t = AgentTracker()
    r.events.forEach { t.apply($0) }
    #expect(t.current(now: now).first { $0.session == "a" }?.needsInput != nil)
}

/// Resilience: the inbox is deleted while watched. The next `ensureRunning()` (the poll loop
/// calls it every minute) re-creates the folder and watches it again.
@Test func watcherRecoversWhenTheInboxIsDeleted() async throws {
    let dir = try tempDir().appendingPathComponent("inbox")
    let fired = AsyncStream.makeStream(of: Void.self)
    let watcher = InboxWatcher(dir: dir) { fired.continuation.yield() }
    watcher.ensureRunning()
    try await Task.sleep(for: .milliseconds(100))
    try FileManager.default.removeItem(at: dir)
    try await Task.sleep(for: .milliseconds(200))
    watcher.ensureRunning()
    try await Task.sleep(for: .milliseconds(200))
    #expect(FileManager.default.fileExists(atPath: dir.path))
    try Data("{}".utf8).write(to: dir.appendingPathComponent("x.json"))
    let got = await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            for await _ in fired.stream { return true }
            return false
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(3))
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
    watcher.stop()
    #expect(got)
}

// MARK: - Update check

private func git(_ dir: URL, _ args: String...) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", dir.path] + args
    p.environment = [
        "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
        "GIT_COMMITTER_EMAIL": "t@t", "HOME": NSTemporaryDirectory(),
    ]
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    return String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

@Test func updateCheckAgainstALocalRepo() async throws {
    let dir = try tempDir()
    _ = try git(dir, "init", "-q", "-b", "main")
    _ = try git(dir, "commit", "-q", "--allow-empty", "-m", "one")
    let built = try git(dir, "rev-parse", "HEAD")

    #expect(await SourceUpdate.check(sourceDir: dir.path, installedCommit: built) == nil)
    #expect(await SourceUpdate.check(sourceDir: dir.path, installedCommit: built + "-dirty") == nil)

    _ = try git(dir, "commit", "-q", "--allow-empty", "-m", "two")
    _ = try git(dir, "commit", "-q", "--allow-empty", "-m", "three")
    let main = try git(dir, "rev-parse", "HEAD")
    #expect(
        await SourceUpdate.check(sourceDir: dir.path, installedCommit: built)
            == .init(newCommits: 2, latest: main))

    // A build from a branch ahead of main is not "behind".
    _ = try git(dir, "checkout", "-q", "-b", "feature")
    _ = try git(dir, "commit", "-q", "--allow-empty", "-m", "wip")
    let feature = try git(dir, "rev-parse", "HEAD")
    #expect(await SourceUpdate.check(sourceDir: dir.path, installedCommit: feature) == nil)

    // Unknown commit (history rewritten): still offer the update, count unknown.
    let unknown = String(repeating: "a", count: 40)
    #expect(
        await SourceUpdate.check(sourceDir: dir.path, installedCommit: unknown)
            == .init(newCommits: nil, latest: main))

    // No repo there: nothing to say.
    #expect(await SourceUpdate.check(sourceDir: "/nonexistent", installedCommit: built) == nil)
}

/// Review concurrency-1: a background process holding the pipes must not hang the call.
@Test func runnerReturnsWhenAGrandchildKeepsThePipesOpen() async throws {
    let start = Date()
    let r = try await CommandRunner.run("/bin/sh", ["-c", "sleep 8 & echo hi"], timeout: 20)
    #expect(String(decoding: r.stdout, as: UTF8.self) == "hi\n")
    #expect(r.exitCode == 0 && !r.timedOut)
    #expect(Date().timeIntervalSince(start) < 4)
}

/// Review: a FIFO named *.json must not block the drain (it would freeze the app every launch).
@Test func drainSkipsAFifoWithoutBlocking() throws {
    let dir = try tempDir()
    let fifo = dir.appendingPathComponent("1-fifo.json").path
    #expect(mkfifo(fifo, 0o644) == 0)
    let start = Date()
    let r = InboxReader.drain(dir)
    #expect(Date().timeIntervalSince(start) < 2)
    #expect(r.rejected.map(\.reason) == ["not a regular file"])
    #expect(!FileManager.default.fileExists(atPath: fifo))
}

// MARK: - Portable repos: .chiefstew.json, agents-only, emitter, Claude Code hooks

@Test func repoConfigFromFileConventionOrNothing() throws {
    let dir = try tempDir()
    #expect(RepoConfig.load(repo: dir.path) == .success(RepoConfig(status: nil, sweep: nil, source: .none)))

    try Data(#"{"v":1,"name":"Mine","status":["./bin/status","--json"]}"#.utf8)
        .write(to: dir.appendingPathComponent(".chiefstew.json"))
    let c = try RepoConfig.load(repo: dir.path).get()
    #expect(c.source == .file && c.status == ["./bin/status", "--json"] && c.sweep == nil)

    try Data(#"{"v":1,"status":"not argv"}"#.utf8).write(to: dir.appendingPathComponent(".chiefstew.json"))
    guard case .failure(.badConfig) = RepoConfig.load(repo: dir.path) else {
        Issue.record("expected badConfig")
        return
    }
}

@Test func customStatusCommandRunsFromTheRepo() async throws {
    let dir = try tempDir()
    try FileManager.default.createDirectory(
        at: dir.appendingPathComponent("bin"), withIntermediateDirectories: true)
    let script = dir.appendingPathComponent("bin/status")
    try Data("#!/bin/sh\necho '{\"v\":1,\"builds\":[]}'\n".utf8).write(to: script)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    try Data(#"{"v":1,"status":["./bin/status"]}"#.utf8).write(to: dir.appendingPathComponent(".chiefstew.json"))
    let client = StatusClient(node: "/usr/bin/false", environment: ["PATH": "/usr/bin:/bin"])
    #expect(try await client.status(repo: dir.path).get()?.builds.isEmpty == true)
    #expect(try await client.sweep(repo: dir.path).get() == nil)  // no sweep command
}

@Test func aRepoWithNoStatusCommandIsAgentsOnly() async throws {
    let dir = try tempDir()
    let client = StatusClient(node: "/usr/bin/false", environment: [:])
    #expect(try await client.status(repo: dir.path).get() == nil)
}

@Test func emitterWritesAContractEventOrNothing() throws {
    let home = try tempDir()
    let paths = Paths(environment: ["CHIEFSTEW_HOME": home.path])
    #expect(Emitter.emit(["kind": "phase.done", "repo": "/r", "build": "1", "phase": 2], paths: paths) == nil)
    try FileManager.default.createDirectory(at: paths.inbox, withIntermediateDirectories: true)
    let file = try #require(
        Emitter.emit(
            ["kind": "agent.needs_input", "repo": "/r", "session": "s", "message": String(repeating: "m", count: 300)],
            paths: paths))
    let event = try Event.parse(Data(contentsOf: file), fallbackDate: .distantPast)
    #expect(event.kind == "agent.needs_input" && event.message?.count == 200)
    #expect(try FileManager.default.contentsOfDirectory(atPath: paths.inbox.path).allSatisfy { !$0.hasPrefix(".") })
}

@Test func claudeHooksInstallKeepOthersAndUninstallCleanly() throws {
    let dir = try tempDir()
    let settings = dir.appendingPathComponent(".claude/settings.json")
    try FileManager.default.createDirectory(
        at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
    let theirs = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo mine"}]}]}}"#
    try Data(theirs.utf8).write(to: settings)
    let cli = "/Applications/Chief Stew.app/Contents/Helpers/chiefstew"

    #expect(ClaudeHooks.state(settings: settings, cli: cli) == .notInstalled)
    let backup = try ClaudeHooks.install(settings: settings, cli: cli)
    #expect(backup != nil)
    #expect(ClaudeHooks.state(settings: settings, cli: cli) == .installed)
    try ClaudeHooks.install(settings: settings, cli: cli)  // idempotent
    let root = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
    let hooks = try #require(root["hooks"] as? [String: Any])
    #expect((hooks["Stop"] as? [Any])?.count == 2)  // theirs + ours, not ours twice
    #expect(root["model"] as? String == "opus")
    #expect(ClaudeHooks.state(settings: settings, cli: "/elsewhere/chiefstew") == .outdated)

    try ClaudeHooks.uninstall(settings: settings)
    let after = try String(contentsOf: settings, encoding: .utf8)
    #expect(!after.contains("chiefstew") && after.contains("echo mine"))
}

@Test func claudeHooksLeaveABrokenSettingsFileAlone() throws {
    let dir = try tempDir()
    let settings = dir.appendingPathComponent("settings.json")
    try Data("{ not json".utf8).write(to: settings)
    #expect(throws: ClaudeHooks.Failure.self) { try ClaudeHooks.install(settings: settings, cli: "/x") }
    #expect(try String(contentsOf: settings, encoding: .utf8) == "{ not json")
}

@Test func hookCommandIsQuotedAndAlwaysSucceeds() {
    let cmd = ClaudeHooks.command(cli: "/Apps/It's Here/chiefstew", sub: "notify")
    #expect(cmd == "[ -x '/Apps/It'\\''s Here/chiefstew' ] && '/Apps/It'\\''s Here/chiefstew' hook notify >/dev/null 2>&1; true # chiefstew")
}

@Test func setupPromptCarriesTheContractAndTheRepoState() {
    let prompt = SetupPrompt.make(
        repo: "/Users/me/my-app", config: RepoConfig(status: nil, sweep: nil, source: .none),
        problem: nil, contract: "# CONTRACT BODY", workflowDoc: "# WORKFLOW DOC", cli: "/Applications/Chief Stew.app/Contents/Helpers/chiefstew")
    #expect(prompt.contains("Set up this repo (my-app)"))
    #expect(prompt.contains("# CONTRACT BODY"))
    #expect(prompt.contains("# WORKFLOW DOC"))
    #expect(prompt.contains(".chiefstew.json"))
    #expect(prompt.contains("'/Applications/Chief Stew.app/Contents/Helpers/chiefstew' check"))
}

// MARK: - Releases (auto-update for the team)

@Test func semverComparison() {
    #expect(SourceUpdate.compare("0.10.0", "0.9.2") == 1)
    #expect(SourceUpdate.compare("1.0.0", "1.0.0") == 0)
    #expect(SourceUpdate.compare("0.1.0", "0.2.0") == -1)
    #expect(SourceUpdate.parse("1.2") == nil)
}

@Test func releasesComeFromTagsFetchedFromOrigin() async throws {
    let root = try tempDir()
    let origin = root.appendingPathComponent("origin")
    let clone = root.appendingPathComponent("clone")
    try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
    _ = try git(origin, "init", "-q", "-b", "main")
    _ = try git(origin, "commit", "-q", "--allow-empty", "-m", "one")
    _ = try git(origin, "tag", "-a", "v0.9.2", "-m", "Chief Stew v0.9.2", "-m", "- older")
    _ = try git(root, "clone", "-q", origin.path, clone.path)

    #expect(SourceUpdate.isClone(clone.path))
    #expect(await SourceUpdate.latestRelease(sourceDir: clone.path)?.tag == "v0.9.2")

    // A new release appears on origin; fetching brings it in, and 0.10.0 beats 0.9.2.
    _ = try git(origin, "commit", "-q", "--allow-empty", "-m", "two")
    _ = try git(origin, "tag", "-a", "v0.10.0", "-m", "Chief Stew v0.10.0", "-m", "- Settings opens in front\n- Faster checks")
    #expect(await SourceUpdate.fetch(sourceDir: clone.path))
    let latest = try #require(await SourceUpdate.latestRelease(sourceDir: clone.path))
    #expect(latest.tag == "v0.10.0" && latest.version == "0.10.0")
    #expect(latest.notes.contains("Settings opens in front"))
}

@Test func aDownloadedCopyCantUpdateAndThatsFine() async throws {
    let dir = try tempDir()  // no .git: like a copy built from a zip
    #expect(!SourceUpdate.isClone(dir.path))
    #expect(await SourceUpdate.fetch(sourceDir: dir.path) == false)
    #expect(await SourceUpdate.latestRelease(sourceDir: dir.path) == nil)
}
