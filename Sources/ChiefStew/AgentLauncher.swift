import AppKit
import ChiefStewCore

/// Coding agents found on the owner's login PATH, and a way to start one in a repo with the
/// setup prompt: a `.command` file Terminal runs (no Automation permission needed). The owner
/// watches and approves in the agent as they normally would.
struct AgentCLI: Identifiable, Hashable {
    var id: String { binary }
    var name: String
    var binary: String
    var path: String
    var style: PromptStyle

    /// How the agent takes a first prompt when started interactively.
    enum PromptStyle: Hashable, Sendable {
        /// `agent "<prompt>"`
        case argument
        /// `agent <flag> "<prompt>"`
        case flag(String)
        /// No flag we rely on: start it empty and put the prompt on the clipboard.
        case clipboard
    }
}

enum AgentLauncher {
    static let known: [(name: String, binary: String, style: AgentCLI.PromptStyle)] = [
        ("Claude Code", "claude", .argument),
        ("Codex", "codex", .argument),
        ("Gemini CLI", "gemini", .flag("-i")),
        ("Cursor Agent", "cursor-agent", .clipboard),
        ("OpenCode", "opencode", .clipboard),
        ("Aider", "aider", .clipboard),
        ("Amp", "amp", .clipboard),
        ("Goose", "goose", .clipboard),
        ("Qwen Code", "qwen", .clipboard),
    ]

    /// Agents on the given PATH (the login shell's), plus the usual install folders: many
    /// installers (Claude Code's own among them) add a shell alias, not a PATH entry.
    static func installed(path: String) -> [AgentCLI] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = [".claude/local", ".local/bin", ".bun/bin", ".npm-global/bin", ".volta/bin", ".cargo/bin"]
            .map { (home as NSString).appendingPathComponent($0) } + ["/opt/homebrew/bin", "/usr/local/bin"]
        var dirs: [String] = []
        for d in path.split(separator: ":").map(String.init) + extra where !dirs.contains(d) { dirs.append(d) }
        return known.compactMap { k in
            for dir in dirs {
                let p = (dir as NSString).appendingPathComponent(k.binary)
                if FileManager.default.isExecutableFile(atPath: p) {
                    return AgentCLI(name: k.name, binary: k.binary, path: p, style: k.style)
                }
            }
            return nil
        }
    }

    /// Opens Terminal in `repo` running `agent` with `prompt`. Returns a message to show.
    @MainActor static func launch(_ agent: AgentCLI, repo: String, prompt: String, loginPath: String) -> String {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/Chief Stew/setup")
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let slug = URL(fileURLWithPath: repo).lastPathComponent.filter { $0.isLetter || $0.isNumber || $0 == "-" }
        let promptFile = dir.appendingPathComponent("\(slug)-prompt.md")
        let script = dir.appendingPathComponent("\(slug)-\(agent.binary).command")
        try? Data(prompt.utf8).write(to: promptFile)

        func q(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let start: String
        let message: String
        // The prompt goes in as one argument, read from the file at run time.
        let promptArg = "\"$(cat \(q(promptFile.path)))\""
        switch agent.style {
        case .argument, .flag:
            var flag = ""
            if case .flag(let f) = agent.style { flag = q(f) + " " }
            start = "exec \(q(agent.path)) \(flag)\(promptArg)"
            message = "\(agent.name) is starting in Terminal with the setup prompt."
        case .clipboard:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prompt, forType: .string)
            start = "echo 'The setup prompt is on your clipboard: paste it into \(agent.name).'; echo; exec \(q(agent.path))"
            message = "\(agent.name) is starting in Terminal. The setup prompt is on your clipboard: paste it in."
        }
        let body = """
            #!/bin/zsh
            # Chief Stew: set up \(slug) with \(agent.name). Safe to delete.
            cd \(q(repo)) || exit 1
            export PATH=\(q(loginPath))
            clear
            echo 'Chief Stew setup for \(slug), using \(agent.name).'
            echo 'Approve what it does as you normally would. Chief Stew shows the result as soon as .chiefstew.json appears.'
            echo
            \(start)

            """
        do {
            try Data(body.utf8).write(to: script)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        } catch {
            return "Couldn't prepare the launcher: \(error.localizedDescription)"
        }
        guard let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else {
            return "Terminal isn't available."
        }
        NSWorkspace.shared.open([script], withApplicationAt: terminal, configuration: NSWorkspace.OpenConfiguration())
        return message
    }
}
