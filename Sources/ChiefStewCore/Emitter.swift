import Foundation

/// Writes one event into the inbox (docs/event-contract.md § 2): skip if there's no inbox,
/// temp file + rename, never throw. Used by the bundled `chiefstew` command.
public enum Emitter {
    /// - Returns: the file written, or nil when skipped or failed.
    @discardableResult
    public static func emit(_ fields: [String: Any], paths: Paths = Paths(), now: Date = Date())
        -> URL?
    {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: paths.inbox.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        var event = fields
        event["v"] = 1
        if event["ts"] == nil {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            event["ts"] = f.string(from: now)
        }
        if let m = event["message"] as? String { event["message"] = String(m.prefix(Event.maxMessage)) }
        guard JSONSerialization.isValidJSONObject(event),
            let data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes]),
            data.count <= Event.maxBytes
        else { return nil }
        let ms = Int(now.timeIntervalSince1970 * 1000)
        let name = "\(ms)-\(getpid())-\(String(format: "%04x", Int.random(in: 0...0xffff))).json"
        let tmp = paths.inbox.appendingPathComponent(".\(name).tmp")
        let dest = paths.inbox.appendingPathComponent(name)
        do {
            try data.write(to: tmp)
            try fm.moveItem(at: tmp, to: dest)
            return dest
        } catch {
            try? fm.removeItem(at: tmp)
            return nil
        }
    }

    /// The main working tree and this checkout's root for a folder, from git (read-only).
    public static func checkout(of folder: String) -> (repo: String, worktree: String)? {
        guard
            let r = try? CommandRunner.runBlocking(
                "/usr/bin/git",
                ["-C", folder, "rev-parse", "--path-format=absolute", "--git-common-dir", "--show-toplevel"],
                cwd: nil, environment: ["GIT_OPTIONAL_LOCKS": "0", "PATH": "/usr/bin:/bin"],
                timeout: 5),
            r.exitCode == 0
        else { return nil }
        let lines = String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
        guard lines.count >= 2 else { return nil }
        var common = PathMatch.normalize(lines[0])
        if common.hasSuffix("/.git") { common = String(common.dropLast(5)) }
        return (common, PathMatch.normalize(lines[1]))
    }
}

/// Chief Stew's Claude Code hooks in a Claude Code settings file (usually
/// `~/.claude/settings.json`, so every repo is covered without changing any repo). Each hook
/// calls the app's bundled `chiefstew` command, is a no-op if the app is gone, prints nothing
/// and always exits 0.
public enum ClaudeHooks {
    /// Claude Code hook event → `chiefstew hook <sub>`.
    public static let events: [(event: String, sub: String)] = [
        ("Notification", "notify"), ("Stop", "stop"), ("UserPromptSubmit", "prompt"),
        ("PostToolUse", "active"), ("SessionEnd", "end"),
    ]
    /// Marks our entries so they can be updated or removed without touching anyone else's.
    public static let marker = "# chiefstew"

    public static var userSettings: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    public static func command(cli: String, sub: String) -> String {
        let q = "'" + cli.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "[ -x \(q) ] && \(q) hook \(sub) >/dev/null 2>&1; true \(marker)"
    }

    public enum State: Equatable, Sendable {
        case notInstalled
        /// Some are missing or point at another copy of the app.
        case outdated
        case installed
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unreadable(String)

        public var description: String {
            switch self {
            case .unreadable(let why): "Couldn't read the Claude Code settings file: \(why). It was left as it is."
            }
        }
    }

    public static func state(settings: URL = userSettings, cli: String) -> State {
        guard let root = try? read(settings) else { return .notInstalled }
        let hooks = root["hooks"] as? [String: Any] ?? [:]
        var ours = 0
        var current = 0
        for (event, sub) in events {
            for command in commands(hooks[event]) where command.contains(marker) {
                ours += 1
                if command == self.command(cli: cli, sub: sub) { current += 1 }
            }
        }
        if ours == 0 { return .notInstalled }
        return current == events.count && ours == events.count ? .installed : .outdated
    }

    /// Adds (or refreshes) our hooks, keeping everything else. Backs the file up first.
    /// - Returns: the backup's URL, if there was a file to back up.
    @discardableResult
    public static func install(settings: URL = userSettings, cli: String) throws -> URL? {
        var root = try read(settings) ?? [:]
        var hooks = removingOurs(root["hooks"] as? [String: Any] ?? [:])
        for (event, sub) in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            groups.append([
                "hooks": [["type": "command", "command": command(cli: cli, sub: sub), "timeout": 10]]
            ])
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try write(root, to: settings)
    }

    @discardableResult
    public static func uninstall(settings: URL = userSettings) throws -> URL? {
        guard var root = try read(settings) else { return nil }
        let hooks = removingOurs(root["hooks"] as? [String: Any] ?? [:])
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return try write(root, to: settings)
    }

    // MARK: helpers

    private static func commands(_ groups: Any?) -> [String] {
        (groups as? [[String: Any]] ?? []).flatMap { group in
            (group["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String }
        }
    }

    private static func removingOurs(_ hooks: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else {
                out[event] = value
                continue
            }
            let kept: [[String: Any]] = groups.compactMap { group in
                guard let list = group["hooks"] as? [[String: Any]] else { return group }
                let others = list.filter { !(($0["command"] as? String)?.contains(marker) ?? false) }
                if others.isEmpty { return nil }
                var g = group
                g["hooks"] = others
                return g
            }
            if !kept.isEmpty { out[event] = kept }
        }
        return out
    }

    /// nil when the file doesn't exist; throws when it exists but isn't a JSON object.
    private static func read(_ url: URL) throws -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? Data(contentsOf: url) else { throw Failure.unreadable("permission denied") }
        if data.allSatisfy({ $0 == 0x20 || $0 == 0x0a || $0 == 0x09 || $0 == 0x0d }) { return [:] }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.unreadable("it isn't a JSON object")
        }
        return root
    }

    private static func write(_ root: [String: Any], to url: URL) throws -> URL? {
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var backup: URL?
        if fm.fileExists(atPath: url.path) {
            let b = url.appendingPathExtension("chiefstew-backup")
            try? fm.removeItem(at: b)
            try fm.copyItem(at: url, to: b)
            backup = b
        }
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try (data + Data("\n".utf8)).write(to: url, options: .atomic)
        return backup
    }
}
