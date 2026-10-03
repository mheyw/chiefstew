import ChiefStewCore
import SwiftUI

/// What the panel's buttons do. The app wires these to NSWorkspace and the pasteboard.
public struct PanelActions {
    public var openFile: (String) -> Void = { _ in }
    /// Opens a read-only copy of `ref:path` from the repo at the first argument.
    public var openFromGit: (String, String) -> Void = { _, _ in }
    /// Brings forward the app running an agent session (falls back to its folder).
    public var goToSession: (String) -> Void = { _ in }
    public var openFolder: (String) -> Void = { _ in }
    public var openURL: (String) -> Void = { _ in }
    public var copy: (String) -> Void = { _ in }
    public var refresh: () -> Void = {}
    public var installUpdate: () -> Void = {}
    public var openRepos: () -> Void = {}
    public var openNotifications: () -> Void = {}
    /// Settings → General.
    public var openSettings: () -> Void = {}
    public var quit: () -> Void = {}

    public init() {}
}

/// The "a newer Chief Stew is available" line at the top of the panel.
public enum UpdateBanner: Equatable, Sendable {
    /// `label`: "v0.3.0" or "3 new commits".
    case available(label: String?)
    case installing
    case failed(log: String)
}

public struct PanelView: View {
    public static let width: CGFloat = 452
    /// Status older than this is worth mentioning (it's normally refreshed every minute).
    static let staleAfter: TimeInterval = 3 * 60

    var board: Board
    var now: Date
    var update: UpdateBanner?
    /// A refresh the owner asked for is running.
    var refreshing: Bool
    var actions: PanelActions

    public init(
        board: Board, now: Date, update: UpdateBanner? = nil, refreshing: Bool = false,
        actions: PanelActions = PanelActions()
    ) {
        self.board = board
        self.now = now
        self.update = update
        self.refreshing = refreshing
        self.actions = actions
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let update { updateLine(update) }
            if isEmpty {
                empty
            } else {
                if !board.problems.isEmpty { section { problems } }
                if !board.needsYou.isEmpty { section { needsYou } }
                if !board.inProgress.isEmpty { section { inProgress } }
                if !board.leftBehind.isEmpty || !board.leftNotes.isEmpty { section { leftBehind } }
            }
            Divider()
            footer
        }
        .frame(width: Self.width, alignment: .leading)
        .font(.system(size: 13))
    }

    private func updateLine(_ update: UpdateBanner) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle").foregroundStyle(Color.accentColor)
            switch update {
            case .available(let label):
                Text("Update available")
                    + Text(label.map { " · \($0)" } ?? "").foregroundColor(.secondary)
                Spacer()
                Button("Install update") { actions.installUpdate() }
                    .buttonStyle(PillButtonStyle(primary: true))
            case .installing:
                Text("Building the update… Chief Stew restarts when it's ready.")
                    .foregroundStyle(.secondary)
                Spacer()
                ProgressView().controlSize(.small)
            case .failed(let log):
                Text("The update didn't install.")
                Spacer()
                Button("Open log") { actions.openFile(log) }.buttonStyle(PillButtonStyle())
                Button("Try again") { actions.installUpdate() }
                    .buttonStyle(PillButtonStyle(primary: true))
            }
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
    }

    private var isEmpty: Bool {
        board.problems.isEmpty && board.needsYou.isEmpty && board.inProgress.isEmpty
            && board.leftBehind.isEmpty && board.leftNotes.isEmpty
    }

    // MARK: header / footer

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Chief Stew").font(.system(size: 13.5, weight: .semibold))
            Spacer()
            headerSummary.font(.system(size: 12)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 9)
    }

    private var headerSummary: Text {
        let parts = board.header.components(separatedBy: " · ")
        return parts.enumerated().reduce(Text("")) { text, item in
            let (i, part) = item
            var piece = Text(part)
            if part.hasSuffix("need you") || part.hasSuffix("needs you") {
                piece = piece.foregroundColor(Palette.attentionText).fontWeight(.semibold)
            } else if part.hasSuffix("stale") {
                piece = piece.foregroundColor(Palette.problemText)
            }
            return i == 0 ? piece : text + Text(" · ") + piece
        }
    }

    /// Icons only, matching the Settings tabs (folder = Repos, bell = Notifications, cog =
    /// General). Each keeps its name for VoiceOver and as a hover tooltip.
    private var footer: some View {
        HStack(spacing: 4) {
            if refreshing {
                ProgressView().controlSize(.small).frame(width: 28, height: 24)
                    .accessibilityLabel("Refreshing")
            } else {
                FooterIcon("Refresh", "arrow.clockwise", action: actions.refresh).keyboardShortcut("r")
            }
            FooterIcon("Repos", "folder", action: actions.openRepos)
            FooterIcon("Notifications", "bell", action: actions.openNotifications)
            FooterIcon("Settings", "gearshape", action: actions.openSettings).keyboardShortcut(",")
            // Only when it means something: status is normally re-read every minute and when the
            // panel opens, so "just now" would be noise. Shown when it's gone stale (asleep, say).
            if let checked = board.checkedAt, now.timeIntervalSince(checked) > Self.staleAfter {
                Text("Last checked \(Durations.ago(now.timeIntervalSince(checked)))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
            }
            Spacer()
            FooterIcon("Quit Chief Stew", "power", action: actions.quit).keyboardShortcut("q")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.primary.opacity(0.03))
    }

    private var empty: some View {
        VStack(spacing: 3) {
            if board.repoNames.isEmpty {
                Text("No repos yet.").font(.system(size: 14))
                Text("Add one to see what its agents and builds are doing.")
                    .foregroundStyle(.secondary)
                Button("Add a repo…") { actions.openRepos() }
                    .buttonStyle(PillButtonStyle(primary: true))
                    .padding(.top, 6)
            } else if !board.loading.isEmpty {
                ProgressView().controlSize(.small).padding(.bottom, 4)
                Text("Checking ").foregroundStyle(.secondary)
                    + Text(board.loading.joined(separator: ", ")).bold()
                    + Text("…").foregroundStyle(.secondary)
            } else {
                Text("All quiet.").font(.system(size: 14))
                Text("No builds in flight in ")
                    .foregroundStyle(.secondary)
                    + Text(board.repoNames.joined(separator: ", ")).bold()
                    + Text(".").foregroundStyle(.secondary)
                if let checked = board.checkedAt, now.timeIntervalSince(checked) > Self.staleAfter {
                    Text("Last checked \(Durations.ago(now.timeIntervalSince(checked))).")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 16)
            .padding(.top, 9)
            .padding(.bottom, 4)
            .overlay(alignment: .top) { Divider().opacity(0.6) }
    }

    // MARK: sections

    private var problems: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Problem", color: Palette.problemText)
            ForEach(board.problems) { p in
                Row {
                    Line1(dot: Palette.problem, name: Text(p.repoName), help: p.repoName) {
                        Text("status failed · since \(p.error.since.formatted(date: .omitted, time: .shortened))")
                    }
                    Text(p.error.message)
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .indented()
                    if let hint = p.error.hint {
                        Text(hint).font(.system(size: 12)).indented()
                    }
                    Actions {
                        Button(refreshing ? "Retrying…" : "Retry") { actions.refresh() }
                            .buttonStyle(PillButtonStyle())
                            .disabled(refreshing)
                        Button("Copy error") { actions.copy(p.error.message) }
                            .buttonStyle(PillButtonStyle())
                    }
                }
            }
        }
    }

    private var needsYou: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(text: "Needs you", color: Palette.attentionText)
            ForEach(Array(board.needsYou.enumerated()), id: \.element.id) { i, item in
                if i > 0 { RowDivider() }
                NeedsRow(item: item, now: now, actions: actions)
            }
        }
    }

    private var inProgress: some View {
        let stale = board.inProgress.compactMap(\.staleSince).min()
        let asOf = board.checkedAt.map { $0.formatted(date: .omitted, time: .shortened) }
        return VStack(alignment: .leading, spacing: 6) {
            SectionTitle(
                text: stale != nil && asOf != nil ? "In progress · as of \(asOf!)" : "In progress")
            ForEach(Array(board.inProgress.enumerated()), id: \.element.id) { i, card in
                if i > 0 { RowDivider() }
                BuildRowView(card: card, now: now, actions: actions)
            }
        }
    }

    private var leftBehind: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionTitle(
                text: "Left behind",
                trailing: board.sweptAt.map { "swept \(Durations.ago(now.timeIntervalSince($0)))" })
            ForEach(Array(board.leftBehind.enumerated()), id: \.element.id) { i, item in
                if i > 0 { RowDivider() }
                Row {
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Palette.attention)
                            .font(.system(size: 11))
                        Text(item.title).fontWeight(.semibold)
                    }
                    Text(item.details.joined(separator: "\n"))
                        .font(.system(size: 11.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .indented()
                    if let command = item.command {
                        Actions {
                            Button("Copy: \(command)") { actions.copy(command) }
                                .buttonStyle(PillButtonStyle())
                        }
                    }
                }
            }
            if !board.leftCleanup.isEmpty {
                RowDivider()
                Row {
                    Text("To clean up").fontWeight(.semibold)
                    Actions {
                        ForEach(board.leftCleanup, id: \.self) { command in
                            Button("Copy: \(command)") { actions.copy(command) }
                                .buttonStyle(PillButtonStyle())
                        }
                    }
                }
            }
            ForEach(board.leftNotes, id: \.self) { note in
                Text(note).font(.system(size: 12)).foregroundStyle(.secondary).padding(.bottom, 6)
            }
        }
    }
}

// MARK: - Rows

struct NeedsRow: View {
    var item: NeedsItem
    var now: Date
    var actions: PanelActions

    var body: some View {
        Row {
            Line1(dot: Palette.attention, name: name, help: label) {
                Text(rightText).foregroundStyle(Palette.attentionText)
            }
            switch item.kind {
            case .gate(let gate):
                HStack(spacing: 0) {
                    if let dots = item.card?.dots, !dots.isEmpty {
                        PhaseDotsView(dots: dots).padding(.trailing, 6)
                    }
                    Text("\(gate.title) ready, waiting on your sign-off")
                }
                .indented()
                Actions {
                    if let artefact = gate.artefact {
                        Button("Open \(URL(fileURLWithPath: artefact).lastPathComponent)") {
                            actions.openFile(artefact)
                        }
                        .buttonStyle(PillButtonStyle(primary: true))
                    } else if let ref = gate.artefactRef {
                        // Not checked out: a read-only copy from the branch.
                        Button("Open \(URL(fileURLWithPath: String(ref.split(separator: ":", maxSplits: 1).last ?? "")).lastPathComponent)") {
                            actions.openFromGit(item.repoPath, ref)
                        }
                        .buttonStyle(PillButtonStyle(primary: true))
                        .help("Not checked out: opens a read-only copy from \(ref.split(separator: ":").first ?? "")")
                    }
                    worktreeButton(primary: gate.artefact == nil && gate.artefactRef == nil)
                    if let approve = gate.approve {
                        Button("Copy approve command") {
                            actions.copy(Self.inWorktree(approve, item.worktree))
                        }
                        .buttonStyle(PillButtonStyle())
                    }
                }
            case .agent(let message, let name):
                Text("“\(message ?? "\(name) is waiting for your input")”").italic().indented()
                Actions {
                    if let session = item.session {
                        Button("Go to session") { actions.goToSession(session) }
                            .buttonStyle(PillButtonStyle(primary: true))
                    }
                    worktreeButton(primary: item.session == nil)
                }
            case .unmerged:
                Text("\(item.card?.state ?? "Closed") · not merged yet").indented()
                Actions { worktreeButton(primary: false) }
            }
        }
    }

    /// The row's identity, for VoiceOver and the name's tooltip.
    private var label: String {
        guard let card = item.card else {
            if case .agent(_, let name) = item.kind { return "\(name) in \(item.repoName)" }
            return item.repoName
        }
        return card.slug.isEmpty ? "\(card.num) in \(item.repoName)" : "\(card.num) \(card.slug)"
    }

    private var name: Text {
        guard let card = item.card else {
            if case .agent(_, let name) = item.kind { return Text("\(name) in \(item.repoName)") }
            return Text(item.repoName)
        }
        return Text("\(card.num) ").monospacedDigit() + Text(card.slug)
    }

    private var rightText: String {
        let age = Durations.short(now.timeIntervalSince(item.since))
        switch item.kind {
        case .gate(let g): return "\(g.title) gate · \(age)"
        case .agent(_, let name): return "\(name) · \(age)"
        case .unmerged: return "Closed \(age) · not merged"
        }
    }

    @ViewBuilder private func worktreeButton(primary: Bool) -> some View {
        if let wt = item.worktree {
            Button("Open worktree") { actions.openFolder(wt) }
                .buttonStyle(PillButtonStyle(primary: primary))
        }
    }

    /// The approve command runs in the build's worktree; make the copied text self-contained.
    nonisolated static func inWorktree(_ command: String, _ worktree: String?) -> String {
        guard let worktree else { return command }
        let quoted = "'" + worktree.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "cd \(quoted) && \(command)"
    }
}

struct BuildRowView: View {
    var card: BuildCard
    var now: Date
    var actions: PanelActions

    var body: some View {
        Row {
            Line1(
                dot: card.staleSince == nil && (!card.parked || card.agentWorking) ? Palette.running : Palette.dot,
                name: Text("\(card.num) ").monospacedDigit() + Text(card.slug),
                tag: card.tag, help: "\(card.num) \(card.slug)"
            ) {
                if let started = card.startedAt {
                    Text(Durations.short(now.timeIntervalSince(started)))
                }
            }
            HStack(spacing: 0) {
                if !card.dots.isEmpty {
                    PhaseDotsView(dots: card.dots, dimmed: card.staleSince != nil || (card.parked && !card.agentWorking))
                        .padding(.trailing, 6)
                }
                Text(line2)
                if let t = card.tasks, t.total > 0 {
                    TaskBar(tasks: t).padding(.leading, 6)
                }
            }
            .indented()
            if let label = card.phaseLabel, !card.state.isEmpty,
                !card.state.lowercased().hasSuffix(label.lowercased())
            {
                Text(card.state).lineLimit(1).truncationMode(.tail)
                    .font(.system(size: 12)).foregroundStyle(.secondary).indented()
                    .help(card.state)
            }
            if !line3.isEmpty {
                Text(line3).font(.system(size: 12)).foregroundStyle(.secondary).indented()
            }
            Actions {
                if let progress = card.progress {
                    Button("Open progress") { actions.openFile(progress) }
                        .buttonStyle(PillButtonStyle())
                }
                if let wt = card.worktree {
                    Button("Open worktree") { actions.openFolder(wt) }
                        .buttonStyle(PillButtonStyle())
                }
                if let url = card.url {
                    Button("Open app ↗") { actions.openURL(url) }.buttonStyle(PillButtonStyle())
                }
            }
        }
    }

    private var line2: String {
        var parts: [String] = []
        if let label = card.phaseLabel { parts.append(label) } else if !card.state.isEmpty {
            parts.append(card.state)
        }
        if let t = card.tasks, t.total > 0 { parts.append("\(t.done)/\(t.total) tasks") }
        return parts.joined(separator: " · ")
    }

    private var line3: String {
        var parts: [String] = []
        if let lane = card.lane { parts.append("\(lane) lane") }
        if let agent = card.agentLine { parts.append(agent) }
        if let behind = card.behind, behind > 0 { parts.append("\(behind) behind main") }
        if card.flags.contains("idle") && card.agentLine == nil {
            parts.append("last commit \(Durations.ago(now.timeIntervalSince(card.lastActivity)))")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Layout pieces

struct Row<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) { content }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct Line1<Trailing: View>: View {
    var dot: Color
    var name: Text
    var tag: String?
    /// Tooltip for the name, which truncates.
    var help: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(dot).frame(width: 8, height: 8)
            name.fontWeight(.semibold).lineLimit(1).truncationMode(.tail)
                .help(help ?? "")
            if let tag {
                Text(tag)
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 5)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.06)))
                    .foregroundStyle(Color.primary.opacity(0.75))
            }
            Spacer(minLength: 8)
            // The name truncates before what's on the right, which carries the row's state.
            trailing.font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                .lineLimit(1)
                .layoutPriority(1)
        }
    }
}

struct Actions<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        FlowRow { content }.padding(.top, 4).indented()
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
    }
}

extension View {
    fileprivate func indented() -> some View { padding(.leading, 15) }
}

/// A footer button that shows only its icon. The name is still there for VoiceOver (it reads
/// the Label's title), as a tooltip, and for keyboard focus.
struct FooterIcon: View {
    var title: String
    var symbol: String
    var action: () -> Void
    @State private var hovering = false

    init(_ title: String, _ symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.system(size: 13, weight: .regular))
                .frame(width: 28, height: 24)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(title)
        .accessibilityLabel(title)
        .onHover { hovering = $0 }
    }
}
