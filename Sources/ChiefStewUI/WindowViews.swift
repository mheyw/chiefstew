import ChiefStewCore
import SwiftUI

// The Chief Stew window: the roadmap and the detail the panel leaves out. The panel stays the
// notification view (docs/plans/roadmap-window.md). Each tab's content is a plain stack, a pure
// function of the board, so it renders offscreen in tests; the split view around it is thin.

/// The whole window: a sidebar of All repos and each repo, and the selected page.
public struct BoardWindowView: View {
    var repos: [RepoView]
    @Binding var selection: WindowSelection
    var now: Date
    var actions: PanelActions

    public init(repos: [RepoView], selection: Binding<WindowSelection>, now: Date, actions: PanelActions) {
        self.repos = repos
        self._selection = selection
        self.now = now
        self.actions = actions
    }

    static let all = "all"

    /// The selected repo, if it's still registered; otherwise All repos.
    private var repo: RepoView? { selection.repo.flatMap { path in repos.first { $0.path == path } } }

    public var body: some View {
        NavigationSplitView {
            List(selection: Binding<String?>(
                get: { repo?.path ?? Self.all },
                set: { selection.repo = $0 == Self.all ? nil : $0 }
            )) {
                Label("All repos", systemImage: "square.stack").tag(Self.all)
                Section("Repos") {
                    ForEach(repos) { r in
                        HStack {
                            Text(r.name).lineLimit(1)
                            Spacer()
                            if r.activeCount > 0 {
                                Text("\(r.activeCount)").foregroundStyle(.secondary).monospacedDigit()
                            }
                        }
                        .tag(r.path)
                        .help(r.path)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 190, max: 260)
        } detail: {
            VStack(spacing: 0) {
                HStack {
                    Text(repo?.name ?? "All repos").font(.system(size: 15, weight: .semibold))
                    Spacer()
                    if repo != nil {
                        Picker("Show", selection: $selection.tab) {
                            ForEach(WindowTab.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                Divider()
                ScrollView {
                    Group {
                        if let repo {
                            switch selection.tab {
                            case .roadmap: RoadmapView(repo: repo, now: now, actions: actions)
                            case .leftBehind:
                                LeftBehindList(
                                    items: repo.left, cleanup: repo.cleanup, notes: repo.leftNotes,
                                    sweptAt: repo.sweptAt, now: now, actions: actions)
                            }
                        } else {
                            AllReposView(repos: repos, now: now, actions: actions)
                        }
                    }
                    .frame(maxWidth: 680, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.system(size: 13))
        }
    }
}

// MARK: - Pages

/// One repo's roadmap: Now (live from status), Up next, the groups in the file's order, and
/// Shipped. Nothing is labelled beyond what the file says and what's counted.
public struct RoadmapView: View {
    var repo: RepoView
    var now: Date
    var actions: PanelActions
    @State private var toggled: Set<String> = []
    @State private var doneShown: Set<String> = []
    @State private var shippedOpen = false
    @State private var hiddenOpen = false

    public init(repo: RepoView, now: Date, actions: PanelActions) {
        self.repo = repo
        self.now = now
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch repo.plan {
            case .ready(let plan):
                nowSection(plan.disagreements)
                if !plan.upNext.isEmpty {
                    WindowSection(title: "Up next") {
                        ForEach(Array(plan.upNext.enumerated()), id: \.offset) { i, row in
                            if i > 0 { RowDivider() }
                            PlanRow(row: row)
                        }
                    }
                }
                ForEach(Array(plan.groups.enumerated()), id: \.offset) { _, group in groupSection(group) }
                if !plan.shipped.isEmpty { shipped(plan.shipped) }
                footer(plan)
            case .notConfigured:
                nowSection([])
                WindowSection(title: "Roadmap") {
                    Text("No roadmap for this repo yet.").font(.system(size: 14))
                    Text("Say in .chiefstew.json where its plan is written down, and this shows what's done, what's next and what's still to come.")
                        .foregroundStyle(.secondary)
                    Actions {
                        Button("Copy roadmap setup prompt") { actions.copyRoadmapPrompt(repo.path) }
                            .buttonStyle(PillButtonStyle(primary: true))
                            .help("For your coding agent, run in this repo: chiefstew prompt roadmap")
                    }
                }
            case .loading:
                nowSection([])
                WindowSection(title: "Roadmap") {
                    Text("Reading the roadmap…").foregroundStyle(.secondary)
                }
            case .problem(let e):
                nowSection([])
                WindowSection(title: "Roadmap", color: Palette.problemText) {
                    Text(e.message).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    if let hint = e.hint { Text(hint).font(.system(size: 12)) }
                    Actions {
                        Button("Copy error") { actions.copy(e.message) }.buttonStyle(PillButtonStyle())
                        Button("Copy roadmap setup prompt") { actions.copyRoadmapPrompt(repo.path) }
                            .buttonStyle(PillButtonStyle())
                    }
                }
            }
        }
    }

    @ViewBuilder private func nowSection(_ disagreements: [Roadmap.Row]) -> some View {
        WindowSection(title: "Now") {
            if repo.now.isEmpty && disagreements.isEmpty {
                Text("Nothing in flight.").foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(Array(repo.now.enumerated()), id: \.element.id) { i, card in
                if i > 0 { RowDivider() }
                BuildRowView(card: card, now: now, actions: actions)
            }
            ForEach(Array(disagreements.enumerated()), id: \.offset) { i, row in
                if i > 0 || !repo.now.isEmpty { RowDivider() }
                PlanRow(row: row, note: "In progress in the plan, not in status")
            }
        }
    }

    private func groupSection(_ group: RoadmapPlan.Group) -> some View {
        let key = group.name
        // Open by default where something is happening: a build live or next, or some done.
        let busy = group.entries.contains { $0.live || $0.row.status == .next } || group.done > 0
        let open = busy != toggled.contains(key)
        let toDo = group.entries.filter { $0.live || $0.row.status != .done }
        let done = group.entries.filter { !$0.live && $0.row.status == .done }
        return WindowSection {
            Button {
                if toggled.contains(key) { toggled.remove(key) } else { toggled.insert(key) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 10)
                    Text(group.name.isEmpty ? "Roadmap" : group.name).fontWeight(.semibold).lineLimit(1)
                    Spacer()
                    Text("\(group.done) done, \(group.toDo) to do")
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.name), \(group.done) done, \(group.toDo) to do")
            if open {
                ForEach(Array(toDo.enumerated()), id: \.offset) { _, e in PlanRow(row: e.row, live: e.live) }
                if !done.isEmpty {
                    Button(doneShown.contains(key) ? "Hide \(done.count) done" : "Show \(done.count) done") {
                        if doneShown.contains(key) { doneShown.remove(key) } else { doneShown.insert(key) }
                    }
                    .buttonStyle(TextLinkStyle()).font(.system(size: 12)).padding(.leading, 16).padding(.top, 2)
                    if doneShown.contains(key) {
                        ForEach(Array(done.enumerated()), id: \.offset) { _, e in PlanRow(row: e.row) }
                    }
                }
            }
        }
    }

    private func shipped(_ groups: [RoadmapPlan.Group]) -> some View {
        WindowSection {
            Button {
                shippedOpen.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: shippedOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary).frame(width: 10)
                    Text("Shipped").fontWeight(.semibold)
                    Spacer()
                    let builds = groups.reduce(0) { $0 + $1.done }
                    Text("\(groups.count) group\(groups.count == 1 ? "" : "s"), \(builds) build\(builds == 1 ? "" : "s")")
                        .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if shippedOpen {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                    HStack {
                        Text(g.name.isEmpty ? "Roadmap" : g.name).lineLimit(1)
                        Spacer()
                        Text(([g.latest.map { "last \($0.formatted(date: .abbreviated, time: .omitted))" }] + ["\(g.done) done"])
                            .compactMap { $0 }.joined(separator: " · "))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 16).padding(.vertical, 2)
                }
            }
        }
    }

    private func footer(_ plan: RoadmapPlan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if hiddenOpen {
                ForEach(Array(plan.hidden.enumerated()), id: \.offset) { _, row in PlanRow(row: row) }
            }
            HStack(spacing: 10) {
                if !plan.hidden.isEmpty {
                    Button(hiddenOpen ? "Hide folded and dropped" : "Show folded and dropped (\(plan.hidden.count))") {
                        hiddenOpen.toggle()
                    }
                    .buttonStyle(TextLinkStyle())
                }
                if let r = repo.roadmap, !r.ref.isEmpty {
                    Button("Open file") { actions.openFromGit(repo.path, "\(r.ref):\(r.file)") }
                        .buttonStyle(TextLinkStyle())
                        .help("A read-only copy of \(r.file) from \(r.ref)")
                }
                Spacer()
                if let r = repo.roadmap, r.fromOrigin {
                    Text(r.fetchedAt.map { "as of the last fetch, \(Durations.ago(now.timeIntervalSince($0)))" } ?? "as of the last fetch")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Every repo at once: what can be compared across them.
public struct AllReposView: View {
    var repos: [RepoView]
    var now: Date
    var actions: PanelActions

    public init(repos: [RepoView], now: Date, actions: PanelActions) {
        self.repos = repos
        self.now = now
        self.actions = actions
    }

    public var body: some View {
        let live = repos.filter { !$0.now.isEmpty }
        let next = repos.filter { !$0.upNext.isEmpty }
        let anyRoadmap = repos.contains { if case .notConfigured = $0.plan { return false } else { return true } }
        let left = repos.flatMap(\.left)
        VStack(alignment: .leading, spacing: 0) {
            WindowSection(title: "Now") {
                if live.isEmpty { Text("Nothing in flight.").foregroundStyle(.secondary).padding(.vertical, 4) }
                ForEach(live) { r in
                    RepoHeading(repo: r, actions: actions)
                    ForEach(Array(r.now.enumerated()), id: \.element.id) { i, card in
                        if i > 0 { RowDivider() }
                        BuildRowView(card: card, now: now, actions: actions)
                    }
                }
            }
            WindowSection(title: "Up next") {
                if next.isEmpty {
                    Text(anyRoadmap ? "Nothing marked next." : "No repo has a roadmap yet. Pick a repo to set one up.")
                        .foregroundStyle(.secondary).padding(.vertical, 4)
                }
                ForEach(next) { r in
                    RepoHeading(repo: r, actions: actions)
                    ForEach(Array(r.upNext.enumerated()), id: \.offset) { _, row in PlanRow(row: row) }
                }
            }
            LeftBehindList(
                items: left, cleanup: PanelView.unique(repos.flatMap(\.cleanup)),
                notes: repos.flatMap { r in r.leftNotes.map { "\(r.name) · \($0)" } },
                sweptAt: repos.compactMap(\.sweptAt).min(), now: now, actions: actions, showRepo: true)
        }
    }
}

/// What sweeps left behind, in full: every database, process and route, with commands to copy.
public struct LeftBehindList: View {
    var items: [LeftItem]
    var cleanup: [String]
    var notes: [String]
    var sweptAt: Date?
    var now: Date
    var actions: PanelActions
    var showRepo = false

    public init(
        items: [LeftItem], cleanup: [String], notes: [String], sweptAt: Date?, now: Date,
        actions: PanelActions, showRepo: Bool = false
    ) {
        self.items = items
        self.cleanup = cleanup
        self.notes = notes
        self.sweptAt = sweptAt
        self.now = now
        self.actions = actions
        self.showRepo = showRepo
    }

    public var body: some View {
        WindowSection(title: "Left behind", trailing: sweptAt.map { "swept \(Durations.ago(now.timeIntervalSince($0)))" }) {
            if items.isEmpty {
                Text(sweptAt == nil ? "No sweep has run here." : "Nothing left behind.")
                    .foregroundStyle(.secondary).padding(.vertical, 4)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { RowDivider() }
                Row(label: item.title) {
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Palette.attention)
                            .font(.system(size: 11))
                        Text(showRepo ? "\(item.repoName) · \(item.title)" : item.title).fontWeight(.semibold)
                    }
                    Text(item.details.joined(separator: "\n"))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .indented()
                    if let command = item.command {
                        Actions {
                            Button("Copy: \(command)") { actions.copy(command) }
                                .buttonStyle(PillButtonStyle())
                                .help(command)
                        }
                    }
                }
            }
            if !cleanup.isEmpty {
                RowDivider()
                Row(label: "To clean up") {
                    Text("To clean up").fontWeight(.semibold)
                    Actions {
                        ForEach(cleanup, id: \.self) { command in
                            Button("Copy: \(command)") { actions.copy(command) }
                                .buttonStyle(PillButtonStyle())
                                .help(command)
                        }
                    }
                }
            }
            ForEach(notes, id: \.self) { note in
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 3)
            }
        }
    }
}

// MARK: - Pieces

/// A text-only button in the accent colour, drawn in SwiftUI so it also renders offscreen.
struct TextLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.accentColor)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// A section of a window page, laid out like the panel's.
struct WindowSection<Content: View>: View {
    var title: String?
    var color: Color = .secondary
    var trailing: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { SectionTitle(text: title, color: color, trailing: trailing) }
            content
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider().opacity(0.6) }
    }
}

/// A repo's name over its rows on the All repos page; opens that repo.
struct RepoHeading: View {
    var repo: RepoView
    var actions: PanelActions

    var body: some View {
        Button(repo.name) { actions.openWindow(WindowSelection(repo: repo.path, tab: .roadmap)) }
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
            .help("Open \(repo.name)")
    }
}

/// One roadmap row: its ID and name, and its status as the file writes it.
struct PlanRow: View {
    var row: Roadmap.Row
    var live = false
    /// Said instead of the status text, when Chief Stew has something to add.
    var note: String?

    var body: some View {
        let label = [row.num, row.name.isEmpty ? nil : row.name].compactMap { $0 }.joined(separator: " ")
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            marker.frame(width: 8, height: 8)
            (Text(row.num.map { "\($0) " } ?? "").monospacedDigit() + Text(row.name.isEmpty ? "(no name)" : row.name))
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
                .help(label)
            if live {
                Text("in flight")
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 5)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Palette.running.opacity(0.15)))
                    .foregroundStyle(Palette.okText)
            }
            Spacer(minLength: 8)
            // A live build is shown from status: what the file says about it isn't repeated.
            let text = note ?? (live ? "" : row.text)
            if !text.isEmpty {
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(note != nil ? Palette.attentionText : .secondary)
                    .lineLimit(1).truncationMode(.tail)
                    .help(note.map { "\($0). The file says: \(row.text)" } ?? row.text)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var marker: some View {
        if live {
            Circle().fill(Palette.running)
        } else {
            switch row.status {
            case .done: Circle().fill(Palette.dot)
            case .active: Circle().fill(Palette.attention)
            case .next: Circle().strokeBorder(Color.accentColor, lineWidth: 1.5)
            case .folded, .dropped: Circle().strokeBorder(Palette.dot.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2]))
            case .planned: Circle().strokeBorder(Palette.dot, lineWidth: 1.2)
            }
        }
    }
}
