import AppKit
import ChiefStewCore
import SwiftUI

/// Add Repo: pick a git repo, switch on agent notifications for every repo (one click), and
/// optionally give it build status, with a generated prompt that sets the repo up.
struct AddRepoWizard: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var repo: String?
    @State private var pickError: String?
    @State private var hooksError: String?
    @State private var config: Result<RepoConfig, StatusError>?
    @State private var test: (ok: Bool, text: String)?
    @State private var testing = false
    @State private var copied = false
    @State private var launchMessage: String?
    @State private var checkResult: WorkflowCheck.Result?
    @State private var showDetails = false
    @State private var watchedStamp: Date?
    @State private var watcher: Task<Void, Never>?
    /// Added by this wizard (not already registered): swapped out if another folder is chosen.
    @State private var addedHere: String?
    /// Opened from a repo's "Set up…" rather than "Add Repo…".
    @State private var settingUp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(settingUp ? "Set up \(repo.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "repo")" : "Add a repo")
                .font(.title2.bold())
            step(1, "Choose a repo", done: alreadyAdded) { chooseStep }
            step(2, "Agent notifications", done: model.hooksState == .installed) { hooksStep }
            step(3, "Build status (optional)", done: (checkResult?.ok ?? test?.ok) == true && isConfigured) { statusStep }
                .disabled(repo == nil)
                .opacity(repo == nil ? 0.5 : 1)
            // The repo is added the moment it's chosen (step 1); steps 2 and 3 are optional
            // extras, so there's no separate "Add" to find.
            HStack {
                if alreadyAdded {
                    Text("Steps 2 and 3 are optional. You can come back to them any time from Repos → Set up…")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { close() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onExitCommand { close() }  // Esc closes too; the repo stays added
        .onAppear {
            model.refreshHooksState()
            if let preset = model.wizardRepo {
                settingUp = true
                select(preset)
            }
        }
    }

    private var alreadyAdded: Bool { repo.map { model.repos.contains($0) } ?? false }
    private var isConfigured: Bool {
        if case .success(let c) = config { return c.source != .none }
        return false
    }

    // MARK: steps

    private var chooseStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                if let repo {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(URL(fileURLWithPath: repo).lastPathComponent).fontWeight(.medium)
                        Text(repo).font(.caption).foregroundStyle(.secondary)
                    }
                    if alreadyAdded {
                        Label("Added. Chief Stew is watching this repo.", systemImage: "checkmark.circle.fill")
                            .font(.caption).foregroundStyle(.green)
                        if !settingUp {
                            Button("Remove") { removeChosen() }.buttonStyle(.link).font(.caption)
                        }
                    }
                } else {
                    Text("Any git repo: existing or brand new.").foregroundStyle(.secondary)
                }
                Spacer()
                if !settingUp { Button(repo == nil ? "Choose…" : "Choose another…") { choose() } }
            }
            let suggestions = RepoStore.suggestions().filter { !model.repos.contains($0) && $0 != repo }
            if repo == nil, !suggestions.isEmpty {
                Menu("Found on this Mac") {
                    ForEach(suggestions.prefix(25), id: \.self) { path in
                        Button(path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) { select(path) }
                    }
                }
                .fixedSize()
            }
            if let pickError { Text(pickError).font(.callout).foregroundStyle(.red) }
        }
    }

    private var hooksStep: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Claude Code tells Chief Stew when it needs you (a question, a permission prompt, a finished turn), in every repo. No repo changes.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                switch model.hooksState {
                case .installed:
                    Label("Installed for all repos", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .outdated:
                    Label("Installed, but out of date", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                    Spacer()
                    Button("Update hooks") { hooksError = model.installHooks() }
                case .notInstalled:
                    Text("Adds 5 hooks to ~/.claude/settings.json (backed up first).").font(.callout)
                    Spacer()
                    Button("Install hooks") { hooksError = model.installHooks() }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let hooksError { Text(hooksError).font(.callout).foregroundStyle(.red) }
        }
    }

    private var statusStep: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Show this repo's builds: phases, gates waiting for sign-off, tasks. The repo describes where it writes these down in .chiefstew.json; your coding agent can write that for you.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            switch config {
            case .success(let c) where c.source == .workflow:
                Label("Described in .chiefstew.json", systemImage: "doc.text").font(.callout)
            case .success(let c) where c.source != .none:
                Text("Status: \(RepoConfig.display(c.status ?? []))  (from \(c.source.rawValue))")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            case .failure(let e):
                Text(e.description).font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                Text("Not described yet, so Chief Stew shows this repo's agents only.").font(.callout)
            }

            // The live result: re-checked whenever .chiefstew.json changes.
            if let r = checkResult {
                HStack {
                    Label(r.summary, systemImage: r.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(r.ok ? .green : .orange)
                    Button(showDetails ? "Hide details" : "Details") { showDetails.toggle() }
                        .buttonStyle(.link)
                }
                .font(.callout)
                if showDetails {
                    ScrollView {
                        Text(r.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 140)
                    .background(Color.primary.opacity(0.04))
                }
            } else if let test {
                Label(test.text, systemImage: test.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.callout).foregroundStyle(test.ok ? .green : .red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                let agents = model.agents
                Menu("Run setup prompt") {
                    ForEach(agents) { agent in
                        Button(agent.name) { run(agent) }
                    }
                    if !agents.isEmpty { Divider() }
                    Button(copied ? "Copied" : "Copy setup prompt") { copyPrompt() }
                }
                .fixedSize()
                if !hasDescriptionFile {
                    Button("Start basic") { startBasic() }
                        .help("Writes a starter .chiefstew.json (one build per worktree or branch), uncommitted")
                }
                Spacer()
                if testing { ProgressView().controlSize(.small) }
                Button("Check again") { check() }
            }
            if let launchMessage {
                Text(launchMessage).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.agents.isEmpty {
                Text("No coding agent found on your PATH. Copy the setup prompt into the agent you use.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var hasDescriptionFile: Bool {
        guard let repo else { return false }
        return FileManager.default.fileExists(atPath: (repo as NSString).appendingPathComponent(RepoConfig.fileName))
    }

    private func step<Content: View>(
        _ n: Int, _ title: String, done: Bool = false, @ViewBuilder _ content: () -> Content
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor.opacity(0.15)).frame(width: 24, height: 24)
                if done {
                    Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.white)
                } else {
                    Text("\(n)").font(.callout.bold()).foregroundStyle(Color.accentColor)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                content()
            }
        }
    }

    // MARK: actions

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        panel.message = "Choose a git repo"
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        select(url.path)
    }

    private func select(_ path: String) {
        let path = PathMatch.normalize(path)
        guard let checkout = Emitter.checkout(of: path) else {
            pickError = "\(URL(fileURLWithPath: path).lastPathComponent) isn't a git repo. Run `git init` in it first."
            return
        }
        pickError = nil
        // Always the main working tree: worktrees of it are found through its status.
        let chosen = checkout.repo
        if checkout.repo != path {
            pickError = "That's a worktree; using its main repo, \(checkout.repo)."
        }
        // Choosing a different folder replaces the one this wizard just added.
        if let previous = addedHere, previous != chosen {
            model.removeRepo(previous)
            addedHere = nil
        }
        repo = chosen
        // Add it now: watching agents is useful straight away, and the rest is optional.
        if !model.repos.contains(chosen) {
            model.addRepo(chosen)
            addedHere = chosen
        }
        test = nil
        checkResult = nil
        launchMessage = nil
        check()
    }

    private func removeChosen() {
        if let repo { model.removeRepo(repo) }
        addedHere = nil
        repo = nil
        config = nil
        test = nil
        checkResult = nil
        launchMessage = nil
        watcher?.cancel()
    }

    private func check() {
        guard let repo else { return }
        config = RepoConfig.load(repo: repo)
        testing = true
        Task {
            if case .success(let c) = config, c.source == .workflow {
                checkResult = await Task.detached { WorkflowCheck.run(repo: repo) }.value
                test = nil
            } else {
                checkResult = nil
                test = await model.testStatus(repo)
            }
            testing = false
        }
        watch(repo)
    }

    /// Re-checks whenever .chiefstew.json changes, while the wizard is open (an agent may be
    /// writing it right now).
    private func watch(_ repo: String) {
        watcher?.cancel()
        let file = (repo as NSString).appendingPathComponent(RepoConfig.fileName)
        watchedStamp = Self.stamp(file)
        watcher = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                let now = Self.stamp(file)
                if now != watchedStamp {
                    watchedStamp = now
                    check()
                    return  // check() starts a fresh watch
                }
            }
        }
    }

    private static func stamp(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func run(_ agent: AgentCLI) {
        guard let repo else { return }
        let problem = test.flatMap { $0.ok ? nil : $0.text }
        launchMessage = AgentLauncher.launch(
            agent, repo: repo, prompt: model.setupPrompt(for: repo, problem: problem),
            loginPath: model.login?.path ?? ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
    }

    private func startBasic() {
        guard let repo, !hasDescriptionFile else { return }
        let file = (repo as NSString).appendingPathComponent(RepoConfig.fileName)
        do {
            try Data(WorkflowInit.basic(repo: repo).utf8).write(to: URL(fileURLWithPath: file))
            launchMessage = "Wrote .chiefstew.json (not committed). Review it, then commit it with the repo."
            check()
        } catch {
            launchMessage = "Couldn't write .chiefstew.json: \(error.localizedDescription)"
        }
    }

    private func copyPrompt() {
        guard let repo else { return }
        let problem = test.flatMap { $0.ok ? nil : $0.text }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.setupPrompt(for: repo, problem: problem), forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private func openTerminal() {
        guard let repo,
            let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal")
        else { return }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: repo, isDirectory: true)], withApplicationAt: terminal,
            configuration: NSWorkspace.OpenConfiguration())
    }

    private func close() {
        watcher?.cancel()
        model.wizardRepo = nil
        model.showAddRepo = false
        dismiss()
    }
}
