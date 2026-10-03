// `chiefstew`: the command bundled in Chief Stew.app (Contents/Helpers/chiefstew).
//
//   chiefstew hook notify|stop|prompt|active|end
//       For Claude Code hooks: reads the hook's JSON on stdin and writes the matching agent
//       event (docs/event-contract.md § 3.2). Prints nothing, always exits 0, and does nothing
//       when Chief Stew isn't installed. Chief Stew's Add Repo wizard installs these hooks.
//
//   chiefstew emit <kind> [--build 012] [--gate review] [--phase 3] [--slug name]
//                         [--lane full] [--message "text"] [--session id] [--agent name]
//                         [--repo path]
//       For a repo's own scripts: report progress (phase.started, gate.waiting, build.closed, …)
//       without writing an emitter. The repo defaults to the git checkout of the current folder.
//       Exits 0 even when skipped, so it never breaks the caller.
//
//   chiefstew status [--repo path]
//       Prints the repo's build status as contract JSON (§ 4): from its .chiefstew.json workflow
//       (the built-in engine) or its status command.
//
//   chiefstew check [--repo path]
//       Explains what Chief Stew makes of the repo's .chiefstew.json workflow: every build, and per
//       field what matched or why not. Exits 1 if anything didn't resolve. For agents to iterate.
//
//   chiefstew init [--repo path] [--force]
//       Writes a starter .chiefstew.json (uncommitted) based on the repo's worktrees and branches.
//
//   chiefstew prompt [--repo path]
//       Prints the setup prompt, for any coding agent: chiefstew prompt | claude -p
//
//   chiefstew version

import AppKit
import ChiefStewCore
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
let paths = Paths()

func usage() -> Never {
    FileHandle.standardError.write(
        Data(
            """
            usage: chiefstew status [--repo path] [--workflow file]   build status as contract JSON
                   chiefstew check  [--repo path] [--workflow file]   explain the repo's workflow description
                   chiefstew init   [--repo path] [--force]   write a starter .chiefstew.json
                   chiefstew prompt [--repo path]     print the setup prompt for a coding agent
                   chiefstew emit <kind> [--build nnn] [--gate name] [--phase n] [--slug s]
                                  [--lane l] [--message text] [--session id] [--agent a] [--repo path]
                   chiefstew hook notify|stop|prompt|active|end     (for Claude Code hooks)
                   chiefstew version

            """.utf8))
    exit(2)
}

func hasInbox() -> Bool {
    var isDir: ObjCBool = false
    return FileManager.default.fileExists(atPath: paths.inbox.path, isDirectory: &isDir) && isDir.boolValue
}

func hook(_ sub: String?) -> Never {
    let kinds = [
        "notify": "agent.needs_input", "stop": "agent.stopped", "prompt": "agent.resumed",
        "active": "agent.active", "end": "agent.ended",
    ]
    guard let sub, let kind = kinds[sub], hasInbox() else { exit(0) }
    let fm = FileManager.default
    // PostToolUse fires after every tool call: stop before reading anything unless some
    // session is waiting for an answer.
    if sub == "active" {
        let waiting = (try? fm.contentsOfDirectory(atPath: paths.waiting.path)) ?? []
        if waiting.isEmpty { exit(0) }
    }
    var input: [String: Any] = [:]
    if isatty(0) == 0 {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        input = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
    guard let session = input["session_id"] as? String, !session.isEmpty else { exit(0) }
    if sub == "active",
        !fm.fileExists(atPath: paths.waiting.appendingPathComponent(Paths.markerName(session)).path)
    {
        exit(0)
    }
    // The session belongs to the project it was started in (Claude Code sets CLAUDE_PROJECT_DIR
    // for hooks), not wherever it last cd'd to.
    let env = ProcessInfo.processInfo.environment
    let cwd = env["CLAUDE_PROJECT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        ?? input["cwd"] as? String ?? fm.currentDirectoryPath
    let checkout = Emitter.checkout(of: cwd)
    var event: [String: Any] = [
        "kind": kind, "repo": checkout?.repo ?? PathMatch.normalize(cwd), "session": session,
        "agent": "claude-code", "producer": "chiefstew-hook",
    ]
    if let c = checkout, c.worktree != c.repo { event["worktree"] = c.worktree }
    // Which app is running the session (Terminal, iTerm, VS Code…), so "Go to session" can
    // bring it forward.
    let host = HostApp.find()
    if let h = host.app {
        event["host_app"] = h.bundleID
        event["host_pid"] = Int(h.pid)
    }
    if let tty = host.tty { event["tty"] = tty }
    if sub == "notify" {
        if let m = input["message"] as? String { event["message"] = m }
        if let t = input["notification_type"] as? String { event["notification_type"] = t }
    }
    Emitter.emit(event, paths: paths)
    // The hook keeps the waiting marker itself, as it fires, so the next tool call or prompt
    // clears the wait even before Chief Stew has read this event.
    let marker = paths.waiting.appendingPathComponent(Paths.markerName(session))
    if sub == "notify" {
        let parsed = try? Event.parse(
            JSONSerialization.data(withJSONObject: event.merging(["v": 1]) { a, _ in a }), fallbackDate: Date())
        if parsed?.asksForInput == true {
            try? fm.createDirectory(at: paths.waiting, withIntermediateDirectories: true)
            fm.createFile(atPath: marker.path, contents: Data())
        }
    } else {
        try? fm.removeItem(at: marker)
    }
    exit(0)
}

/// Walks up from this hook process to the GUI app hosting the agent (and the terminal device).
enum HostApp {
    static func find() -> (app: (pid: pid_t, bundleID: String)?, tty: String?) {
        var pid = getppid()
        var tty: String?
        for _ in 0..<24 {
            guard pid > 1, let info = proc(pid) else { break }
            if tty == nil, info.kp_eproc.e_tdev != -1, let name = devname(info.kp_eproc.e_tdev, S_IFCHR) {
                tty = String(cString: name)
            }
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular,
                let bundle = app.bundleIdentifier
            {
                return ((pid, bundle), tty)
            }
            pid = info.kp_eproc.e_ppid
        }
        return (nil, tty)
    }

    private static func proc(_ pid: pid_t) -> kinfo_proc? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info
    }
}

func emit(_ rest: [String]) -> Never {
    guard let kind = rest.first, !kind.hasPrefix("--") else { usage() }
    var event: [String: Any] = ["kind": kind, "producer": "chiefstew-emit"]
    var repoFolder = FileManager.default.currentDirectoryPath
    var i = 1
    while i < rest.count {
        let flag = rest[i]
        guard i + 1 < rest.count else { usage() }
        let value = rest[i + 1]
        switch flag {
        case "--build", "--gate", "--slug", "--lane", "--message", "--session", "--agent":
            event[String(flag.dropFirst(2))] = value
        case "--phase":
            guard let n = Int(value) else { usage() }
            event["phase"] = n
        case "--repo": repoFolder = value
        default: usage()
        }
        i += 2
    }
    guard hasInbox() else { exit(0) }
    let checkout = Emitter.checkout(of: repoFolder)
    event["repo"] = checkout?.repo ?? PathMatch.normalize(repoFolder)
    if let c = checkout, c.worktree != c.repo { event["worktree"] = c.worktree }
    // Validate against the contract before writing, so a typo is reported, not dropped.
    if let data = try? JSONSerialization.data(withJSONObject: event.merging(["v": 1]) { a, _ in a }) {
        do {
            _ = try Event.parse(data, fallbackDate: Date())
        } catch {
            FileHandle.standardError.write(Data("chiefstew emit: \(error)\n".utf8))
            exit(0)
        }
    }
    Emitter.emit(event, paths: paths)
    exit(0)
}

/// The repo for status/check/init/prompt: `--repo`, else the git checkout of the current folder
/// (its main working tree).
func repoArg(_ rest: [String]) -> String {
    // An explicit --repo is taken as given; the current folder goes up to its repo's root.
    if let i = rest.firstIndex(of: "--repo"), rest.indices.contains(i + 1) {
        return PathMatch.normalize(URL(fileURLWithPath: rest[i + 1]).path)
    }
    let folder = FileManager.default.currentDirectoryPath
    return Emitter.checkout(of: folder)?.repo ?? PathMatch.normalize(folder)
}

/// This executable's real location, however it was called (by name from PATH, or a symlink).
func selfURL() -> URL {
    URL(fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]).resolvingSymlinksInPath()
}

/// Contents/Helpers/chiefstew → Contents/Resources/<name> in the enclosing app.
func bundled(_ name: String) -> String? {
    let helpers = selfURL().deletingLastPathComponent()
    let url = helpers.deletingLastPathComponent().appendingPathComponent("Resources/\(name)")
    return try? String(contentsOf: url, encoding: .utf8)
}

func status(_ rest: [String]) -> Never {
    let repo = repoArg(rest)
    if let file = workflowArg(rest) {
        switch RepoConfig.load(repo: repo, file: file) {
        case .success(let c) where c.workflow != nil:
            let report = WorkflowEngine(repo: repo, spec: c.workflow!).run().report
            let data = (try? JSONSerialization.data(withJSONObject: StatusJSON.encode(report), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
            print(String(decoding: data, as: UTF8.self))
            exit(0)
        case .success: FileHandle.standardError.write(Data("\(file) has no workflow\n".utf8))
        case .failure(let e): FileHandle.standardError.write(Data("\(e.description)\n".utf8))
        }
        exit(1)
    }
    let client = StatusClient(node: nil, environment: ProcessInfo.processInfo.environment)
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var out: Swift.Result<StatusReport?, StatusError> = .success(nil)
    Task {
        var c = client
        if let login = try? await LoginEnvironment.resolve() { c = StatusClient(login: login) }
        out = await c.status(repo: repo)
        sem.signal()
    }
    sem.wait()
    switch out {
    case .success(let report?):
        let data = (try? JSONSerialization.data(withJSONObject: StatusJSON.encode(report), options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
        exit(0)
    case .success(nil):
        FileHandle.standardError.write(Data("No status for this repo (no .chiefstew.json): only its agents are shown. Try: chiefstew init\n".utf8))
        exit(1)
    case .failure(let e):
        FileHandle.standardError.write(Data("\(e.description)\n".utf8))
        exit(1)
    }
}

/// `--workflow file`: try a description without writing it into the repo.
func workflowArg(_ rest: [String]) -> String? {
    rest.firstIndex(of: "--workflow").flatMap { rest.indices.contains($0 + 1) ? rest[$0 + 1] : nil }
}

func check(_ rest: [String]) -> Never {
    let repo = repoArg(rest)
    let r = WorkflowCheck.run(repo: repo, file: workflowArg(rest))
    print(r.text)
    // From Chief Stew's journal: does this repo also send agent events of its own?
    var state = EventState()
    for e in EventJournal(paths: paths).replay() { state.apply(e) }
    if let seen = state.doubledRepos(now: Date())[PathMatch.normalize(repo)] {
        print("\n" + EventState.doubledHint + " (last seen \(Durations.ago(Date().timeIntervalSince(seen))))")
    }
    exit(r.ok ? 0 : 1)
}

func initRepo(_ rest: [String]) -> Never {
    let repo = repoArg(rest)
    let file = (repo as NSString).appendingPathComponent(RepoConfig.fileName)
    if FileManager.default.fileExists(atPath: file) && !rest.contains("--force") {
        FileHandle.standardError.write(Data("\(file) already exists (use --force to replace it)\n".utf8))
        exit(1)
    }
    do {
        try Data(WorkflowInit.basic(repo: repo).utf8).write(to: URL(fileURLWithPath: file))
    } catch {
        FileHandle.standardError.write(Data("couldn't write \(file): \(error.localizedDescription)\n".utf8))
        exit(1)
    }
    print("Wrote \(file) (not committed). Next: chiefstew check")
    exit(0)
}

func prompt(_ rest: [String]) -> Never {
    let repo = repoArg(rest)
    let config = (try? RepoConfig.load(repo: repo).get()) ?? RepoConfig(status: nil, sweep: nil, source: .none)
    // Called by name from PATH: say `chiefstew`; otherwise the full path of this copy.
    let argv0 = CommandLine.arguments[0]
    let cli = argv0.contains("/") ? selfURL().path : argv0
    print(SetupPrompt.make(
        repo: repo, config: config, problem: nil, contract: bundled("event-contract.md"),
        workflowDoc: bundled("workflow.md"), cli: cli))
    exit(0)
}

switch args.first {
case "status": status(Array(args.dropFirst()))
case "check": check(Array(args.dropFirst()))
case "init": initRepo(Array(args.dropFirst()))
case "prompt": prompt(Array(args.dropFirst()))
case "hook": hook(args.dropFirst().first)
case "emit": emit(Array(args.dropFirst()))
case "version", "--version":
    // Contents/Helpers/chiefstew → the enclosing .app's Info.plist.
    let app = selfURL().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let info = Bundle(url: app)?.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String ?? "dev"
    let build = info["CFBundleVersion"] as? String ?? "?"
    print("chiefstew \(version) (build \(build))")
default: usage()
}
