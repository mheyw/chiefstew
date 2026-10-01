import Foundation

/// Runs a registered repo's status and sweep commands (docs/event-contract.md § 4–6), as named
/// by its `RepoConfig`. No shell: argv is run directly, in the repo, with `GIT_OPTIONAL_LOCKS=0`.
/// The commands must be read-only; Chief Stew never passes anything that writes.
public struct StatusClient: Sendable {
    /// nil: no Node on the login PATH; only repos whose command starts with `node` mind.
    public var node: String?
    public var environment: [String: String]
    public var statusTimeout: TimeInterval = 20
    public var sweepTimeout: TimeInterval = 60

    public init(node: String?, environment: [String: String]) {
        self.node = node
        self.environment = environment
    }

    public init(login: LoginEnvironment, base: [String: String] = ProcessInfo.processInfo.environment) {
        var env = base
        env["PATH"] = login.path
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["NO_COLOR"] = "1"
        self.init(node: login.node, environment: env)
    }

    /// `.success(nil)`: the repo has no status command, so it's watched for agents only.
    public func status(repo: String) async -> Swift.Result<StatusReport?, StatusError> {
        switch config(repo) {
        case .failure(let e): return .failure(e)
        case .success(let c):
            if let spec = c.workflow { return .success(await Self.runEngine(repo: repo, spec: spec)) }
            guard let argv = c.status else { return .success(nil) }
            return await run(repo: repo, argv: argv, timeout: statusTimeout).map { $0 }
        }
    }

    /// The built-in engine, off the caller's thread (it runs a few read-only git commands).
    public static func runEngine(repo: String, spec: WorkflowSpec) async -> StatusReport {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                cont.resume(returning: WorkflowEngine(repo: repo, spec: spec).run().report)
            }
        }
    }

    public func sweep(repo: String) async -> Swift.Result<SweepReport?, StatusError> {
        switch config(repo) {
        case .failure(let e): return .failure(e)
        case .success(let c):
            guard let argv = c.sweep else { return .success(nil) }
            return await run(repo: repo, argv: argv, timeout: sweepTimeout).map { $0 }
        }
    }

    private func config(_ repo: String) -> Swift.Result<RepoConfig, StatusError> {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repo, isDirectory: &isDir), isDir.boolValue
        else { return .failure(.repoMissing(repo)) }
        return RepoConfig.load(repo: repo)
    }

    /// argv[0]: `node` is the Node found through the login shell; a path with a `/` is taken
    /// relative to the repo; anything else is looked up on the login shell's PATH.
    func executable(_ name: String, repo: String) -> String? {
        let fm = FileManager.default
        if name == "node" { return node }
        if name.contains("/") {
            let path = name.hasPrefix("/") ? name : (repo as NSString).appendingPathComponent(name)
            return fm.isExecutableFile(atPath: path) ? path : nil
        }
        for dir in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") {
            let path = (String(dir) as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    private func run<T: Decodable>(repo: String, argv: [String], timeout: TimeInterval) async
        -> Swift.Result<T, StatusError>
    {
        let command = RepoConfig.display(argv)
        guard let exe = executable(argv[0], repo: repo) else {
            return .failure(.launch(command, "\(argv[0]) not found"))
        }
        let result: CommandResult
        do {
            result = try await CommandRunner.run(
                exe, Array(argv.dropFirst()), cwd: repo, environment: environment, timeout: timeout)
        } catch {
            return .failure(.launch(command, String(describing: error)))
        }
        if result.timedOut { return .failure(.timeout(command, timeout)) }
        guard result.exitCode == 0 else {
            let last = result.stderrText.split(separator: "\n").last.map(String.init) ?? ""
            return .failure(.failed(command, result.exitCode, last))
        }
        let text = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("{") else { return .failure(.noJSONSupport(command)) }
        do {
            return .success(try JSONDecoder().decode(T.self, from: Data(text.utf8)))
        } catch {
            return .failure(.badJSON(command, String(describing: error)))
        }
    }
}

public enum StatusError: Error, Equatable, CustomStringConvertible {
    case repoMissing(String)
    case badConfig(String, String)
    case launch(String, String)
    case timeout(String, TimeInterval)
    case failed(String, Int32, String)
    /// The command printed text, not the contract's JSON.
    case noJSONSupport(String)
    case badJSON(String, String)

    public var description: String {
        switch self {
        case .repoMissing(let p): "repo not found at \(p) (moved or deleted?)"
        case .badConfig(let f, let why): "\(f): \(why)"
        case .launch(let c, let e): "\(c): couldn't start (\(e))"
        case .timeout(let c, let t): "\(c): timed out after \(Int(t)) s"
        case .failed(let c, let code, let err):
            "\(c): exit \(code)" + (err.isEmpty ? "" : " · “\(err)”")
        case .noJSONSupport(let c): "\(c): printed text, not JSON"
        case .badJSON(let c, let e): "\(c): bad JSON (\(e.prefix(160)))"
        }
    }

    /// What the owner can do, when there's something specific.
    public var hint: String? {
        switch self {
        case .noJSONSupport, .badJSON:
            "The status command doesn't speak Chief Stew's contract yet. Repos → this repo → Copy setup prompt."
        case .badConfig: "Fix .chiefstew.json, or remove it to watch agents only."
        case .repoMissing: "Update the repo list if it moved."
        default: nil
        }
    }
}
