import AppKit
import ChiefStewCore
import ChiefStewUI
import Observation
import os
import SwiftUI

/// Owns the live state: polls each repo's status and sweep, drains the inbox, posts
/// notifications, and hands the views a `Board`. What to show and what to notify are decided
/// by ChiefStewCore's `Board.make` and `NotificationPlanner`.
@MainActor @Observable
final class AppModel {
    static let statusInterval: Duration = .seconds(60)
    static let sweepInterval: Duration = .seconds(15 * 60)
    static let eventDebounce: Duration = .seconds(2)
    static let panelFreshness: TimeInterval = 10

    private(set) var snapshots: [String: RepoSnapshot] = [:]
    private(set) var tracker = AgentTracker()
    private(set) var repos: [String]
    /// Bumped by the poll loop so time-based state (needs-input expiry) re-evaluates.
    private(set) var tick = Date()
    private(set) var permission: Notifier.Permission = .unknown
    private(set) var login: LoginEnvironment?
    private(set) var loginError: String?
    var settingsTab: SettingsTab = .repos
    private(set) var update: UpdateBanner?

    var settings: Preferences {
        didSet {
            guard settings != oldValue else { return }
            Self.save(settings, key: "settings")
            if settings.nodePath != oldValue.nodePath {
                login = nil
                Task { await refreshAll() }
            }
            updateNotifications()
        }
    }

    /// `$CHIEFSTEW_REPOS` is set: the repo list is fixed for this run and not saved.
    let reposOverridden = ProcessInfo.processInfo.environment["CHIEFSTEW_REPOS"] != nil

    @ObservationIgnored private let paths = Paths()
    @ObservationIgnored private let notifier = Notifier()
    @ObservationIgnored private var ledger: NoticeLedger
    @ObservationIgnored private var watcher: InboxWatcher?
    @ObservationIgnored private var inflight = Set<String>()
    @ObservationIgnored private var rerun = Set<String>()
    @ObservationIgnored private var sweeping = Set<String>()
    @ObservationIgnored private var pending: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var loops: [Task<Void, Never>] = []
    @ObservationIgnored private let log = Logger(subsystem: "com.mheyw.chiefstew", category: "app")
    @ObservationIgnored private var lastUpdateCheck = Date.distantPast
    @ObservationIgnored private var updateLatest: String?

    static let updateCheckInterval: TimeInterval = 5 * 60
    static let updateNoticeID = "chiefstew-update"
    static let updateLog = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Chief Stew/update.log").path

    init() {
        repos = RepoStore.load()
        settings = Self.load(Preferences.self, key: "settings") ?? Preferences()
        ledger = Self.load(NoticeLedger.self, key: "noticeLedger") ?? NoticeLedger()
        // Agent waits survive a relaunch (and a one-click update): the events that set them
        // were deleted from the inbox long ago (review: relaunch-drops-agent-waits).
        if let data = try? Data(contentsOf: paths.agents),
            let saved = try? JSONDecoder().decode(AgentTracker.self, from: data)
        {
            tracker = saved
            tracker.prune(now: Date())
        }
    }

    private func saveAgents() {
        if let data = try? JSONEncoder().encode(tracker) {
            try? data.write(to: paths.agents, options: .atomic)
        }
        writeWaitingMarkers()
    }

    /// `waiting/<session>` exists while that session needs input, so the PostToolUse
    /// hook can skip starting Node for every tool call unless something is waiting
    /// (contract § 1). Session IDs are reduced to safe filename characters.
    private func writeWaitingMarkers() {
        let fm = FileManager.default
        let dir = paths.waiting
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let want = Set(
            tracker.current(now: Date()).filter { $0.needsInput != nil }.map { Paths.markerName($0.session) })
        let have = Set((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
        for name in have.subtracting(want) { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
        for name in want.subtracting(have) {
            fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data())
        }
    }

    func board(now: Date) -> Board {
        Board.make(
            repos: repos.map { snapshots[$0] ?? RepoSnapshot(path: $0) },
            agents: tracker.current(now: now), now: now)
    }

    // MARK: lifecycle

    func start() {
        guard loops.isEmpty else { return }
        log.info("starting; repos: \(self.repos.joined(separator: ", "), privacy: .public)")
        // Creating the inbox marks Chief Stew as installed, so emitters start writing events.
        try? FileManager.default.createDirectory(at: paths.inbox, withIntermediateDirectories: true)
        let watcher = InboxWatcher(dir: paths.inbox) { [weak self] in
            Task { @MainActor in self?.drainInbox() }
        }
        watcher.ensureRunning()
        self.watcher = watcher
        drainInbox()

        notifier.onClick = { [weak self] id, target in
            guard let self else { return }
            if id == Self.updateNoticeID {
                if case .available = self.update { self.installUpdate() }
                if case .failed = self.update { self.installUpdate() }
            } else if id.hasPrefix("agent-"), let at = id.lastIndex(of: "@") {
                // "agent-<session>@<since>": take you to that session.
                self.goToSession(String(id[id.index(id.startIndex, offsetBy: 6)..<at]))
            } else if let target {
                self.open(target)
            }
        }
        notifier.onPermissionChange = { [weak self] permission in
            self?.permission = permission
            self?.heartbeat()
            self?.updateNotifications()
        }

        writeWaitingMarkers()
        // Housekeeping runs on its own loop, so a slow or stuck status call can never stop
        // the heartbeat (review: concurrency-1).
        loops.append(
            Task { [weak self] in
                await self?.notifier.requestPermission()
                self?.announceUpdateIfNew()
                while !Task.isCancelled {
                    guard let self else { return }
                    self.tick = Date()
                    self.tracker.prune(now: self.tick)
                    self.watcher?.ensureRunning()
                    await self.notifier.refreshPermission()  // it can change in System Settings
                    self.heartbeat()
                    self.drainInbox()
                    self.writeWaitingMarkers()
                    self.updateNotifications()
                    self.checkUpdateWatchdog()
                    try? await Task.sleep(for: Self.statusInterval)
                }
            })
        loops.append(
            Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshAll()
                    await self?.checkForUpdate(.background)
                    try? await Task.sleep(for: Self.statusInterval)
                }
            })
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.log.info("woke from sleep; refreshing")
                self?.login = nil  // PATH or node may have changed
                self?.heartbeat()
                await self?.refreshAll()
                await self?.sweepAll()
                await self?.checkForUpdate(.background)
            }
        }
    }

    /// On quit: drop the heartbeat so emitters go back to their own notifications at once.
    func stop() {
        try? FileManager.default.removeItem(at: paths.heartbeat)
    }

    func panelOpened() {
        let now = Date()
        let stale = repos.contains { repo in
            guard let at = snapshots[repo]?.statusAt else { return true }
            return now.timeIntervalSince(at) > Self.panelFreshness
        }
        tick = now
        if stale { Task { await refreshAll() } }
        Task { await checkForUpdate(.panel) }
    }

    // MARK: updates

    /// Set by build.sh: the source folder and the commit this copy was built from. Only the
    /// installed copy offers updates; a dev run from build/ doesn't.
    private var source: (dir: String, commit: String)? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard LaunchAtLogin.isInstalled,
            let dir = info["ChiefStewSourceDir"] as? String,
            let commit = info["ChiefStewSourceCommit"] as? String, commit != "unknown"
        else { return nil }
        return (dir, commit)
    }

    /// What an available update would install: a release tag, or main.
    struct UpdateTarget: Equatable {
        var ref: String
        var label: String?
        var notes: String?
        var id: String
    }

    @ObservationIgnored private var updateTarget: UpdateTarget?
    private(set) var lastUpdateFetch: (at: Date, ok: Bool)?
    var panelOpen = false {
        didSet { if !panelOpen { installIfAutomatic() } }
    }

    var installedVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Updates are a progressive enhancement: only a copy built from a git clone of the repo
    /// can update itself. Nil when this copy can't (a dev run, or built from a downloaded zip).
    var updatesPossible: Bool { source.map { SourceUpdate.isClone($0.dir) } ?? false }

    /// One line for Settings → Updates.
    var updateStatus: String {
        guard source != nil else { return "This copy isn't installed in /Applications, so it doesn't update itself." }
        guard updatesPossible else {
            return "Installed from a download, so it can't update itself. For automatic updates, install from a git clone of the Chief Stew repo (see its README)."
        }
        if checkingNow { return "Checking for updates…" }
        if update == .installing { return "Installing \(updateTarget?.label ?? "the update")… Chief Stew restarts by itself in about a minute." }
        if settings.updateMode == .off { return "Updates are off. You're on v\(installedVersion)." }
        if let t = updateTarget, case .available = update { return "\(t.label ?? "An update") is available." }
        if settings.updateChannel == .releases, let f = lastUpdateFetch, !f.ok {
            return "Couldn't reach GitHub (checked \(Durations.ago(Date().timeIntervalSince(f.at)))). Updates resume when it can."
        }
        let checked = lastUpdateCheck == .distantPast ? "" : ", checked \(Durations.ago(Date().timeIntervalSince(lastUpdateCheck)))"
        return "Up to date: v\(installedVersion)\(checked)."
    }

    enum CheckReason {
        /// The hourly loop, launch and wake.
        case background
        /// The panel opened: at most every 10 minutes.
        case panel
        /// Check now: straight away, and install whatever it finds.
        case now
    }

    /// True while a Check now is running, so the click always visibly does something.
    private(set) var checkingNow = false

    func checkForUpdate(_ reason: CheckReason = .background) async {
        guard let source, update != .installing, updatesPossible else { return }
        if reason == .now { checkingNow = true }
        defer { if reason == .now { checkingNow = false } }
        guard settings.updateMode != .off || reason == .now else {
            update = nil
            return
        }
        // A release check is a small `git fetch` of tags; main is purely local.
        let interval: TimeInterval
        switch (reason, settings.updateChannel) {
        case (.now, _): interval = 0
        case (.panel, .releases): interval = 10 * 60
        case (.panel, .main): interval = 30
        case (.background, .releases): interval = 3600
        case (.background, .main): interval = Self.updateCheckInterval
        }
        let now = Date()
        guard now.timeIntervalSince(lastUpdateCheck) >= interval else { return }
        lastUpdateCheck = now

        var target: UpdateTarget?
        switch settings.updateChannel {
        case .releases:
            let ok = await SourceUpdate.fetch(sourceDir: source.dir, path: login?.path ?? "/usr/bin:/bin")
            lastUpdateFetch = (Date(), ok)
            if let rel = await SourceUpdate.latestRelease(sourceDir: source.dir),
                SourceUpdate.compare(rel.version, installedVersion) > 0
            {
                target = UpdateTarget(ref: rel.tag, label: rel.tag, notes: rel.notes, id: rel.tag)
            }
        case .main:
            if let a = await SourceUpdate.check(sourceDir: source.dir, installedCommit: source.commit) {
                let label = a.newCommits.map { "\($0) new commit\($0 == 1 ? "" : "s")" }
                target = UpdateTarget(ref: "refs/heads/main", label: label, notes: nil, id: a.latest)
            }
        }
        guard let target else {
            if case .available = update { update = nil }
            updateTarget = nil
            notifier.withdraw([Self.updateNoticeID])  // an old "update available" is now wrong
            return
        }
        if case .failed = update, target.id == updateTarget?.id, reason != .now { return }  // the same build failed
        updateTarget = target
        update = .available(label: target.label)

        if reason == .now {
            installUpdate()  // you asked: no waiting
        } else if settings.updateMode == .automatic {
            installIfAutomatic()
        } else {
            let key = "updateNotifiedFor"
            if permission == .granted, UserDefaults.standard.string(forKey: key) != target.id {
                UserDefaults.standard.set(target.id, forKey: key)
                notifier.post(
                    Notice(
                        id: Self.updateNoticeID, title: "Chief Stew \(target.label ?? "update") is available",
                        body: "Click to install it.", open: nil, isReminder: true))
            }
        }
    }

    /// Automatic mode waits only while the panel is open (seconds), so the app never restarts
    /// under your click. Settings may be open: it's reopened where it was after the restart.
    func installIfAutomatic() {
        guard settings.updateMode == .automatic, case .available = update, !panelOpen else { return }
        installUpdate()
    }

    /// Set at launch when an update restarted the app with Settings open: reopen it there.
    private(set) var reopenSettingsTab: SettingsTab? = {
        let d = UserDefaults.standard
        defer { d.removeObject(forKey: "reopenSettingsTab") }
        return d.string(forKey: "reopenSettingsTab").flatMap(SettingsTab.init(rawValue:))
    }()

    func takeReopenSettingsTab() -> SettingsTab? {
        defer { reopenSettingsTab = nil }
        return reopenSettingsTab
    }

    var settingsOpen: Bool { NSApp.windows.contains { $0.identifier == WindowFront.settingsID && $0.isVisible } }

    /// After an update, the new copy says so once, with the release notes.
    func announceUpdateIfNew() {
        let d = UserDefaults.standard
        let now = "\(installedVersion) \(source?.commit ?? "")"
        defer { d.set(now, forKey: "lastRunBuild") }
        guard let before = d.string(forKey: "lastRunBuild"), before != now,
            let pending = d.string(forKey: "pendingUpdateLabel")
        else { return }
        let notes = d.string(forKey: "pendingUpdateNotes") ?? ""
        d.removeObject(forKey: "pendingUpdateLabel")
        d.removeObject(forKey: "pendingUpdateNotes")
        guard permission == .granted else { return }
        let summary = notes.split(separator: "\n").prefix(3).map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "- ")) }
            .joined(separator: " · ")
        notifier.post(
            Notice(
                id: "chiefstew-updated", title: "Chief Stew updated to \(pending)",
                body: summary.isEmpty ? "You're on v\(installedVersion)." : summary, open: nil, isReminder: false))
    }

    /// Runs `build.sh install` from the source folder, detached: it quits this copy, swaps in
    /// the new one and reopens it. If the build fails, this copy is still running and says so.
    @ObservationIgnored private var installStarted: Date?

    /// A build that never finishes (or a quit that never came) shouldn't leave "Building…"
    /// forever (review: install-update-no-retry-no-timeout).
    private func checkUpdateWatchdog() {
        guard update == .installing, let started = installStarted,
            Date().timeIntervalSince(started) > 20 * 60
        else { return }
        update = .failed(log: Self.updateLog)
    }

    func installUpdate() {
        guard let source, update != .installing else { return }
        let fm = FileManager.default
        let logURL = URL(fileURLWithPath: Self.updateLog)
        try? fm.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: logURL.path, contents: Data("\(Date()) installing from \(source.dir)\n".utf8))
        guard let logHandle = try? FileHandle(forWritingTo: logURL) else { return }
        logHandle.seekToEndOfFile()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // `update` builds a clean export of the release tag (or main), never whatever is checked
        // out in the source folder.
        let target = updateTarget ?? UpdateTarget(ref: "refs/heads/main", label: nil, notes: nil, id: "")
        process.arguments = [(source.dir as NSString).appendingPathComponent("build.sh"), "update", target.ref]
        UserDefaults.standard.set(target.label ?? "the latest version", forKey: "pendingUpdateLabel")
        if settingsOpen { UserDefaults.standard.set(settingsTab.rawValue, forKey: "reopenSettingsTab") }
        UserDefaults.standard.set(target.notes ?? "", forKey: "pendingUpdateNotes")
        process.currentDirectoryURL = URL(fileURLWithPath: source.dir)
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (login?.path).map { "\($0):/usr/bin:/bin:/usr/sbin:/sbin" } ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                // Still here: on success build.sh would have quit and replaced this copy.
                self.log.error("update exited \(status) without replacing this copy")
                self.update = .failed(log: Self.updateLog)
            }
        }
        do {
            try process.run()
            update = .installing
            installStarted = Date()
            notifier.withdraw([Self.updateNoticeID])
            log.info("update: build.sh install started (pid \(process.processIdentifier))")
        } catch {
            update = .failed(log: Self.updateLog)
        }
    }

    // MARK: notifications

    /// While Chief Stew can notify, `alive` stays fresh and emitters hand their notifications
    /// over (contract § 2.5). Without permission there's no heartbeat, so emitters keep
    /// notifying and nothing is lost.
    private func heartbeat() {
        let file = paths.heartbeat
        guard permission == .granted else {
            try? FileManager.default.removeItem(at: file)
            return
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: file.path) {
            try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        } else {
            fm.createFile(atPath: file.path, contents: Data())
        }
    }

    private func updateNotifications() {
        guard permission == .granted else { return }
        let now = Date()
        let loaded = Set(repos.filter { snapshots[$0]?.statusAt != nil })
        let plan = NotificationPlanner.plan(
            board: board(now: now), ledger: ledger, settings: settings, now: now, loaded: loaded)
        plan.post.forEach(notifier.post)
        notifier.withdraw(plan.withdraw)
        if plan.ledger != ledger {
            ledger = plan.ledger
            Self.save(ledger, key: "noticeLedger")
        }
    }

    // MARK: repo setup (the Add Repo wizard)

    /// The wizard sheet is open.
    var showAddRepo = false
    /// Pre-selects a repo in the wizard (from a repo's "Set up…" button).
    var wizardRepo: String?
    private(set) var hooksState: ClaudeHooks.State = .notInstalled

    /// The bundled `chiefstew` command (Contents/Helpers/chiefstew); nil in a bare `swift run`.
    var cliPath: String? {
        let path = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/chiefstew").path
        return FileManager.default.isExecutableFile(atPath: path) ? path : nil
    }

    /// Coding agents on the login PATH, for "Run setup prompt".
    var agents: [AgentCLI] {
        AgentLauncher.installed(path: login?.path ?? ProcessInfo.processInfo.environment["PATH"] ?? "")
    }

    var contract: String? { Self.bundled("event-contract") }
    var workflowDoc: String? { Self.bundled("workflow") }

    private static func bundled(_ name: String) -> String? {
        Bundle.main.url(forResource: name, withExtension: "md")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    func refreshHooksState() {
        hooksState = cliPath.map { ClaudeHooks.state(cli: $0) } ?? .notInstalled
    }

    /// Adds Chief Stew's Claude Code hooks to ~/.claude/settings.json (backed up first).
    func installHooks() -> String? {
        guard let cli = cliPath else { return "This copy has no bundled chiefstew command; install the app with ./build.sh install." }
        do {
            try ClaudeHooks.install(cli: cli)
            refreshHooksState()
            return nil
        } catch {
            return String(describing: error)
        }
    }

    func removeHooks() -> String? {
        do {
            try ClaudeHooks.uninstall()
            refreshHooksState()
            return nil
        } catch {
            return String(describing: error)
        }
    }

    /// Runs a repo's status command once, for the wizard: a one-line result or the error.
    func testStatus(_ repo: String) async -> (ok: Bool, text: String) {
        guard case .success(let client) = await client() else {
            return (false, loginError ?? "couldn't find node")
        }
        switch await client.status(repo: repo) {
        case .success(nil): return (true, "No status command: this repo's agents only.")
        case .success(let report?):
            let n = report.builds.count
            return (true, "Read \(n) build\(n == 1 ? "" : "s") in flight.")
        case .failure(let e): return (false, e.description + (e.hint.map { "\n\($0)" } ?? ""))
        }
    }

    func setupPrompt(for repo: String, problem: String?) -> String {
        let config = (try? RepoConfig.load(repo: repo).get()) ?? RepoConfig(status: nil, sweep: nil, source: .none)
        return SetupPrompt.make(
            repo: repo, config: config, problem: problem, contract: contract, workflowDoc: workflowDoc,
            cli: cliPath ?? "/Applications/Chief Stew.app/Contents/Helpers/chiefstew")
    }

    // MARK: repos

    func addRepo(_ path: String) {
        let path = PathMatch.normalize(path)
        guard !repos.contains(path) else { return }
        setRepos(repos + [path])
        Task { await refresh(path) }
    }

    func removeRepo(_ path: String) {
        setRepos(repos.filter { $0 != path })
        snapshots[path] = nil
        updateNotifications()
    }

    private func setRepos(_ list: [String]) {
        repos = list
        if !reposOverridden { UserDefaults.standard.set(list, forKey: RepoStore.key) }
    }

    // MARK: status and sweep

    func refreshAll() async {
        await withTaskGroup(of: Void.self) { group in
            for repo in repos { group.addTask { await self.refresh(repo) } }
        }
    }

    func refresh(_ repo: String) async {
        guard !inflight.contains(repo) else {
            rerun.insert(repo)  // an event arrived mid-run: go again once this one lands
            return
        }
        inflight.insert(repo)
        defer { inflight.remove(repo) }

        var snap = snapshots[repo] ?? RepoSnapshot(path: repo)
        switch await client() {
        case .failure(let error):
            if snap.statusError?.message != error.description {
                snap.statusError = RepoError(
                    message: error.description, since: Date(),
                    hint: "Set the node path in Settings → General.")
            }
        case .success(let client):
            switch await client.status(repo: repo) {
            case .success(let report):
                snap.status = report ?? StatusReport(builds: [])
                snap.agentsOnly = report == nil
                snap.statusAt = Date()
                snap.statusError = nil
                if let skipped = report?.skippedRows, skipped > 0 {
                    log.error("\(repo, privacy: .public): skipped \(skipped) bad status rows")
                }
                // Sweep rides on status: it runs once status proves the repo speaks the contract,
                // then whenever the last sweep is older than the sweep interval.
                let due = snap.sweepAt.map {
                    Date().timeIntervalSince($0) > TimeInterval(Self.sweepInterval.components.seconds)
                } ?? true
                if due { Task { await self.sweep(repo) } }
            case .failure(let error):
                log.error("\(repo, privacy: .public): \(error.description, privacy: .public)")
                if snap.statusError?.message != error.description {
                    snap.statusError = RepoError(
                        message: error.description, since: Date(), hint: error.hint)
                }
            }
        }
        guard repos.contains(repo) else { return }  // removed while running
        // Write back only what refresh owns: a sweep may have landed while status ran
        // (review: concurrency-2).
        var current = snapshots[repo] ?? RepoSnapshot(path: repo)
        current.status = snap.status
        current.statusAt = snap.statusAt
        current.statusError = snap.statusError
        current.agentsOnly = snap.agentsOnly
        snapshots[repo] = current
        updateNotifications()
        dumpDebugState()

        if rerun.remove(repo) != nil {
            inflight.remove(repo)
            await refresh(repo)
        }
    }

    func sweepAll() async {
        for repo in repos { await sweep(repo) }
    }

    /// Only for repos whose status already speaks the contract.
    func sweep(_ repo: String) async {
        guard snapshots[repo]?.status != nil, snapshots[repo]?.agentsOnly == false,
            !sweeping.contains(repo),
            case .success(let client) = await client()
        else { return }
        sweeping.insert(repo)
        defer { sweeping.remove(repo) }
        switch await client.sweep(repo: repo) {
        case .success(let report):
            guard let report else { return }  // no sweep command
            snapshots[repo]?.sweep = report
            snapshots[repo]?.sweepAt = Date()
            dumpDebugState()
        case .failure(let error):
            log.error("\(repo, privacy: .public) sweep: \(error.description, privacy: .public)")
        }
    }

    private func client() async -> Result<StatusClient, LoginEnvironment.Failure> {
        if let login { return .success(StatusClient(login: login)) }
        do {
            let found = try await LoginEnvironment.resolve(nodeOverride: settings.nodePath)
            log.info("node \(found.node ?? "none", privacy: .public) \(found.nodeVersion ?? "", privacy: .public)")
            login = found
            loginError = nil
            return .success(StatusClient(login: found))
        } catch let error as LoginEnvironment.Failure {
            log.error("\(error.description, privacy: .public)")
            loginError = error.description
            return .failure(error)
        } catch {
            loginError = String(describing: error)
            return .failure(.notFound(String(describing: error)))
        }
    }

    // MARK: inbox

    func drainInbox() {
        let result = InboxReader.drain(paths.inbox)
        if !result.rejected.isEmpty || result.expired > 0 {
            log.info("inbox: \(result.rejected.count) rejected, \(result.expired) expired")
        }
        for var event in result.events {
            guard let repo = registered(event.repo) else {
                // Chief Stew's heartbeat told the emitter to stay quiet, so say it here.
                log.info("inbox: \(event.kind, privacy: .public) for unregistered \(event.repo, privacy: .public)")
                postFromEvent(event)
                continue
            }
            // A worktree outside the repo is ignored: an event can't point Chief Stew at an
            // arbitrary path to open later (review: event-path-launches-apps).
            if let wt = event.worktree, !PathMatch.contains(repo, wt) { event.worktree = nil }
            tracker.apply(event)
            if event.kind == "gate.waiting", snapshots[repo]?.statusError != nil {
                postFromEvent(event)  // the board can't show it while status is failing
            }
            scheduleRefresh(repo)
        }
        if !result.events.isEmpty {
            saveAgents()
            updateNotifications()  // agent needs-input notifies straight away
            dumpDebugState()
        }
    }

    /// Dev only: with `$CHIEFSTEW_DEBUG_DIR` set, write the menu-bar text and a panel render
    /// after every update, so a run can be checked without screen-recording permission.
    private func dumpDebugState() {
        guard let dir = ProcessInfo.processInfo.environment["CHIEFSTEW_DEBUG_DIR"] else { return }
        let url = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let now = Date()
        let board = board(now: now)
        let menu = board.menu
        let text = """
            menu: \(menu.title ?? "(icon only)") attention=\(menu.attention) warning=\(menu.warning)
            header: \(board.header)
            needs: \(board.needsYou.map(\.menuTitle).joined(separator: ", "))
            problems: \(board.problems.map(\.error.message).joined(separator: " | "))
            permission: \(permission) ledger: \(ledger.sent.keys.sorted().joined(separator: ", "))

            """
        try? Data(text.utf8).write(to: url.appendingPathComponent("state.txt"))
        let renderer = ImageRenderer(
            content: PanelView(board: board, now: now)
                .background(Color(nsColor: .windowBackgroundColor)))
        renderer.scale = 2
        if let tiff = renderer.nsImage?.tiffRepresentation,
            let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        {
            try? png.write(to: url.appendingPathComponent("panel.png"))
        }
    }

    private func postFromEvent(_ event: Event) {
        guard permission == .granted, let notice = NotificationPlanner.notice(forEvent: event)
        else { return }
        let enabled = event.kind == "gate.waiting" ? settings.notifyGates : settings.notifyAgents
        if enabled { notifier.post(notice) }
    }

    private func registered(_ path: String) -> String? {
        let target = PathMatch.normalize(path)
        return repos.first { PathMatch.normalize($0) == target }
    }

    private func scheduleRefresh(_ repo: String) {
        pending[repo]?.cancel()
        pending[repo] = Task { [weak self] in
            try? await Task.sleep(for: Self.eventDebounce)
            guard !Task.isCancelled else { return }
            await self?.refresh(repo)
        }
    }

    // MARK: actions

    /// A notification's target: folders go to the worktree app, files to their default app.
    private func open(_ target: String) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target, isDirectory: &isDir) else { return }
        if isDir.boolValue {
            WorktreeApps.open(target, with: settings.worktreeApp)
        } else {
            openFile(target)
        }
    }

    /// Brings forward the app running an agent's session (Terminal, iTerm, VS Code…), as recorded
    /// by `chiefstew hook`. Falls back to opening the session's folder.
    func goToSession(_ session: String) {
        guard let s = tracker.sessions[session] else { return }
        var host: NSRunningApplication?
        if let pid = s.hostPid, let app = NSRunningApplication(processIdentifier: pid_t(pid)),
            s.hostApp == nil || app.bundleIdentifier == s.hostApp
        {
            host = app
        } else if let bundle = s.hostApp {
            host = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
        }
        guard let host else {
            WorktreeApps.open(s.path, with: settings.worktreeApp)
            return
        }
        // Activating an editor with several windows brings forward the last one used, which may
        // be another project. These editors focus the window that already has a folder open when
        // asked to open it, so open the session's folder instead.
        if let bundle = host.bundleIdentifier, Self.folderWindowEditors.contains(bundle) {
            WorktreeApps.open(s.path, with: bundle)
            return
        }
        host.activate()
    }

    /// Editors with one window per folder that focus the existing window when that folder is opened.
    private static let folderWindowEditors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium",
        "com.todesktop.230313mzl4w4u92",  // Cursor
        "com.exafunction.windsurf",
    ]

    /// A file that's only in git (`ref:path`, the build isn't checked out): read it with
    /// `git show` (read-only), save a read-only copy in the cache folder, and open that.
    func openFromGit(repo: String, spec: String) async {
        guard let colon = spec.firstIndex(of: ":") else { return }
        let ref = String(spec[..<colon])
        let path = String(spec[spec.index(after: colon)...])
        guard !repo.isEmpty, !path.contains(".."),
            let r = try? await CommandRunner.run(
                "/usr/bin/git", ["-C", repo, "show", spec],
                environment: ["GIT_OPTIONAL_LOCKS": "0", "PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()],
                timeout: 10),
            r.exitCode == 0, r.stdout.count <= 2 * 1024 * 1024
        else {
            log.error("couldn't read \(spec, privacy: .public) from git")
            return
        }
        let safe = { (s: String) in s.map { $0.isLetter || $0.isNumber || "-_.".contains($0) ? $0 : "_" } }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/Chief Stew/artefacts")
            .appendingPathComponent(String(safe(URL(fileURLWithPath: repo).lastPathComponent)))
            .appendingPathComponent(String(safe(ref)))
        let file = dir.appendingPathComponent(URL(fileURLWithPath: path).lastPathComponent)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        try? fm.removeItem(at: file)
        guard (try? r.stdout.write(to: file)) != nil else { return }
        try? fm.setAttributes([.posixPermissions: 0o444], ofItemAtPath: file.path)  // a copy, not the real file
        openFile(file.path)
    }

    /// Files from status (gate artefacts, progress.md) open in their default app, but never
    /// anything that could run: apps, scripts, .command files are revealed in Finder instead.
    private func openFile(_ path: String) {
        let url = URL(fileURLWithPath: path)
        let runnable: Set<String> = ["app", "command", "tool", "sh", "zsh", "bash", "workflow", "scpt", "terminal", "pkg", "dmg"]
        if runnable.contains(url.pathExtension.lowercased())
            || NSWorkspace.shared.isFilePackage(atPath: path)
            || FileManager.default.isExecutableFile(atPath: path)
        {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func actions(openSettings: @escaping (SettingsTab) -> Void) -> PanelActions {
        var a = PanelActions()
        a.openFile = { [weak self] in self?.openFile($0) }
        a.openFromGit = { [weak self] repo, spec in Task { await self?.openFromGit(repo: repo, spec: spec) } }
        a.goToSession = { [weak self] in self?.goToSession($0) }
        a.openFolder = { [weak self] in WorktreeApps.open($0, with: self?.settings.worktreeApp) }
        a.openURL = { if let url = URL(string: $0) { NSWorkspace.shared.open(url) } }
        a.copy = {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString($0, forType: .string)
        }
        a.refresh = { [weak self] in
            Task {
                await self?.refreshAll()
                await self?.sweepAll()
            }
        }
        a.installUpdate = { [weak self] in self?.installUpdate() }
        a.openRepos = { [weak self] in
            if self?.repos.isEmpty == true { self?.showAddRepo = true }
            openSettings(.repos)
        }
        a.openNotifications = { openSettings(.notifications) }
        a.openSettings = { openSettings(.general) }
        a.quit = { NSApplication.shared.terminate(nil) }
        return a
    }

    // MARK: persistence

    private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

enum SettingsTab: String, Hashable { case repos, notifications, general }
