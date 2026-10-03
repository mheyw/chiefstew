import AppKit
import ChiefStewCore
import ChiefStewUI
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            ReposPane(model: model)
                .tabItem { Label("Repos", systemImage: "folder") }
                .tag(SettingsTab.repos)
            NotificationsPane(model: model)
                .tabItem { Label("Notifications", systemImage: "bell") }
                .tag(SettingsTab.notifications)
            GeneralPane(model: model)
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
        }
        .frame(width: 520)
        .padding(20)
        // Tag the window so it can be found again, and bring it to the front when it opens.
        .background(WindowAccessor { window in
            window.identifier = WindowFront.settingsID
            WindowFront.raise(window)
        })
    }
}

// MARK: - Repos

private struct ReposPane: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Chief Stew watches these repos. It runs each one's read-only status command and never changes a repo.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if model.reposOverridden {
                Text("The list is set by $CHIEFSTEW_REPOS for this run, so changes here aren't saved.")
                    .font(.callout).foregroundStyle(Palette.attentionText)
            }
            List {
                if model.repos.isEmpty {
                    Text("No repos yet. Add one to start.").foregroundStyle(.secondary)
                }
                ForEach(model.repos, id: \.self) { repo in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(URL(fileURLWithPath: repo).lastPathComponent).fontWeight(.medium)
                            Text(repo).font(.caption).foregroundStyle(.secondary)
                            Text(sourceLine(repo)).font(.caption).foregroundStyle(.secondary)
                            if let error = model.snapshots[repo]?.statusError {
                                Text(error.message).font(.caption).foregroundStyle(Palette.problemText)
                                    .lineLimit(2)
                            }
                            if model.events.doubledRepos(now: model.tick)[PathMatch.normalize(repo)] != nil {
                                Text(EventState.doubledHint).font(.caption).foregroundStyle(Palette.attentionText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer()
                        Button("Set up…") {
                            model.wizardRepo = repo
                            model.showAddRepo = true
                        }
                        Button("Remove") { model.removeRepo(repo) }
                    }
                    .padding(.vertical, 2)
                }
            }
            .frame(minHeight: 160)
            HStack {
                Button("Add Repo…") {
                    model.wizardRepo = nil
                    model.showAddRepo = true
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
        }
        .sheet(isPresented: $model.showAddRepo) { AddRepoWizard(model: model) }
    }

    private func sourceLine(_ repo: String) -> String {
        switch RepoConfig.load(repo: repo) {
        case .success(let c):
            switch c.source {
            case .none: return "Agents only (no status command)"
            case .workflow, .file: return "Build status from \(c.source.rawValue)"
            }
        case .failure: return "Broken .chiefstew.json"
        }
    }
}

// MARK: - Notifications

private struct NotificationsPane: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                switch model.permission {
                case .granted:
                    StatusLabel("Chief Stew can send notifications.", systemImage: "checkmark.circle", tint: .green)
                    Text("While it runs, repo scripts that support Chief Stew leave notifying to it.")
                        .font(.callout).foregroundStyle(.secondary)
                case .denied:
                    StatusLabel("Notifications are off for Chief Stew.", systemImage: "bell.slash", tint: .orange)
                    Text("Repo scripts that notify on their own keep doing so meanwhile.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Open Notification Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                case .unknown:
                    Text("Waiting for notification permission…").foregroundStyle(.secondary)
                }
            }
            Section("Notify me when") {
                Toggle("A gate is waiting for sign-off", isOn: $model.settings.notifyGates)
                Toggle("An agent needs input", isOn: $model.settings.notifyAgents)
                Toggle("A closed build isn't merged", isOn: $model.settings.notifyUnmerged)
            }
            Section {
                Picker("Remind me while a gate waits", selection: $model.settings.reminderMinutes) {
                    ForEach(Preferences.reminderChoices, id: \.self) { minutes in
                        Text(minutes == 0 ? "Never" : "Every \(Durations.short(TimeInterval(minutes * 60)))")
                            .tag(minutes)
                    }
                }
                Text("Progress never notifies. Only things that need you do.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - General

private struct GeneralPane: View {
    @Bindable var model: AppModel
    @State private var launchAtLogin = LaunchAtLogin.isOn
    @State private var launchError: String?
    @State private var nodePath = ""
    @State private var hooksError: String?

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            try LaunchAtLogin.set(on)
                            launchError = nil
                        } catch {
                            launchError = error.localizedDescription
                            launchAtLogin = LaunchAtLogin.isOn
                        }
                    }
                if !LaunchAtLogin.isInstalled {
                    Text("This copy runs from \(Bundle.main.bundlePath). Install it to /Applications first, or login will launch this copy.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let launchError {
                    Text(launchError).font(.callout).foregroundStyle(Palette.problemText)
                }
            }
            Section("Updates") {
                Text(model.updateStatus).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if model.updatesPossible {
                    Picker("When an update is available", selection: $model.settings.updateMode) {
                        Text("Install automatically").tag(UpdateMode.automatic)
                        Text("Ask first").tag(UpdateMode.ask)
                        Text("Don't check").tag(UpdateMode.off)
                    }
                    Picker("Update to", selection: $model.settings.updateChannel) {
                        Text("Releases").tag(UpdateChannel.releases)
                        Text("Latest main (for developing Chief Stew)").tag(UpdateChannel.main)
                    }
                    HStack {
                        Text(model.update == .installing
                            ? "Installing… Chief Stew builds it (about a minute), restarts, and reopens Settings here."
                            : "Checks hourly. An update installs in the background and Chief Stew restarts by itself.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if model.checkingNow { ProgressView().controlSize(.small) }
                        Button("Check now") { Task { await model.checkForUpdate(.now) } }
                            .disabled(model.update == .installing || model.checkingNow)
                    }
                }
            }
            Section("Claude Code hooks") {
                HStack {
                    switch model.hooksState {
                    case .installed: Text("Installed for all repos (~/.claude/settings.json)")
                    case .outdated: Text("Installed, but out of date").foregroundStyle(Palette.attentionText)
                    case .notInstalled: Text("Not installed").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.hooksState != .installed {
                        Button(model.hooksState == .outdated ? "Update" : "Install") { hooksError = model.installHooks() }
                    }
                    if model.hooksState != .notInstalled {
                        Button("Remove") { hooksError = model.removeHooks() }
                    }
                }
                if let hooksError { Text(hooksError).font(.callout).foregroundStyle(Palette.problemText) }
            }
            Section {
                Picker("Open worktrees in", selection: $model.settings.worktreeApp) {
                    Text("Finder").tag(String?.none)
                    ForEach(WorktreeApps.installed(), id: \.bundleID) { app in
                        Text(app.name).tag(Optional(app.bundleID))
                    }
                }
            }
            Section("Node") {
                TextField("Path to node (leave empty to find it through your login shell)", text: $nodePath)
                    .onSubmit { model.settings.nodePath = nodePath.isEmpty ? nil : nodePath }
                if let login = model.login {
                    Text(login.node.map { "Using \($0) (\(login.nodeVersion ?? "unknown version"))" }
                        ?? "No node on your login PATH. Only repos whose status command starts with `node` need it.")
                        .font(.callout).foregroundStyle(.secondary)
                } else if let error = model.loginError {
                    Text(error).font(.callout).foregroundStyle(Palette.problemText)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            nodePath = model.settings.nodePath ?? ""
            model.refreshHooksState()
        }
    }
}
