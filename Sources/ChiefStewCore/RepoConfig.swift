import Foundation

/// How Chief Stew reads a repo's build status (docs/event-contract.md § 4a).
///
/// 0. `.chiefstew.json` (JSON5) with a `"workflow"`: a description the built-in engine turns
///    into status. Nothing from the repo runs (docs/workflow.md).
/// 1. `.chiefstew.json` with a `"status"` command (argv) that prints contract JSON, and
///    optionally a `"sweep"` command: the escape hatch for processes a description can't express.
/// 2. No `.chiefstew.json`: Chief Stew shows the repo's agents only.
public struct RepoConfig: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        case workflow = ".chiefstew.json (workflow)"
        case file = ".chiefstew.json"
        case none = "agents only"
    }

    public var name: String?
    public var status: [String]?
    public var sweep: [String]?
    public var workflow: WorkflowSpec?
    public var source: Source
    /// The plan around the builds (contract § 4c). Optional, and next to any source.
    public var roadmap: RoadmapSpec?
    /// A broken `roadmap` is reported on its own: it never stops status.
    public var roadmapProblem: String?
    /// Top-level keys Chief Stew doesn't know (a misspelt `roadmp`, say), for `chiefstew check`.
    public var unknownKeys: [String] = []
    /// Keys inside `workflow` and `roadmap` this copy doesn't know: ignored, and reported by
    /// `chiefstew check`. A description that uses a newer copy's keys still works here.
    public var warnings: [WorkflowSpec.Problem] {
        (workflow?.warnings ?? []) + (roadmap?.warnings ?? [])
    }

    public static let fileName = ".chiefstew.json"
    static let knownKeys: Set<String> = ["v", "name", "status", "sweep", "workflow", "roadmap"]

    public init(name: String? = nil, status: [String]?, sweep: [String]?, source: Source) {
        self.name = name
        self.status = status
        self.sweep = sweep
        self.source = source
    }

    /// Reads the repo's config. A broken `.chiefstew.json` is an error, not a silent fallback.
    /// - Parameter file: read this config instead of the repo's own (`chiefstew check --workflow`).
    public static func load(repo: String, file override: String? = nil) -> Result<RepoConfig, StatusError> {
        let fm = FileManager.default
        let file = override ?? (repo as NSString).appendingPathComponent(fileName)
        if override != nil, !fm.fileExists(atPath: file) { return .failure(.badConfig(file, "not found")) }
        if fm.fileExists(atPath: file) {
            guard let data = fm.contents(atPath: file), data.count < 64 * 1024,
                let json = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
                    as? [String: Any]
            else { return .failure(.badConfig(file, "not a JSON (or JSON5) object")) }
            if let v = json["v"] as? Int, v != 1 {
                return .failure(.badConfig(file, "unsupported v \(v)"))
            }
            func command(_ key: String) -> Result<[String]?, StatusError> {
                guard let value = json[key], !(value is NSNull) else { return .success(nil) }
                guard let argv = value as? [String], !argv.isEmpty, !argv[0].isEmpty else {
                    return .failure(.badConfig(file, "\"\(key)\" must be a non-empty array of strings"))
                }
                return .success(argv)
            }
            let status: [String]?
            let sweep: [String]?
            switch (command("status"), command("sweep")) {
            case (.failure(let e), _), (_, .failure(let e)): return .failure(e)
            case (.success(let s), .success(let w)): (status, sweep) = (s, w)
            }
            var c = RepoConfig(name: json["name"] as? String, status: status, sweep: sweep, source: .file)
            if let w = json["workflow"] {
                if status != nil {
                    return .failure(.badConfig(file, "use either \"workflow\" or \"status\", not both"))
                }
                switch WorkflowSpec.parse(w) {
                case .failure(let problems): return .failure(.badConfig(file, problems.description))
                case .success(let spec):
                    c.source = .workflow
                    c.workflow = spec
                }
            }
            if let r = json["roadmap"] {
                switch RoadmapSpec.parse(r) {
                case .success(let spec): c.roadmap = spec
                case .failure(let problems): c.roadmapProblem = problems.description
                }
            }
            c.unknownKeys = json.keys.filter { !knownKeys.contains($0) }.sorted()
            return .success(c)
        }
        return .success(RepoConfig(status: nil, sweep: nil, source: .none))
    }

    /// Shell-style display of a command, for the UI and error messages.
    public static func display(_ argv: [String]) -> String {
        argv.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }
}
