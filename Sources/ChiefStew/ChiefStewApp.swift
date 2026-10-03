import ChiefStewCore
import ChiefStewUI
import SwiftUI

@main
struct ChiefStewApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        model.start()
        _model = State(initialValue: model)
        AppDelegate.model = model
    }

    var body: some Scene {
        MenuBarExtra {
            PanelHost(model: model)
        } label: {
            LabelHost(model: model)
        }
        .menuBarExtraStyle(.window)

        // The window: the roadmap and the detail the panel leaves out. Opened from the panel only.
        Window("Chief Stew", id: AppModel.boardWindowID) {
            BoardWindowHost(model: model)
        }
        .defaultSize(width: 860, height: 620)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// The menu-bar icon. Also reopens Settings and the window at launch when an update restarted
/// the app with them open (the label is the one view that exists as soon as the app starts).
private struct LabelHost: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MenuBarLabel(state: model.board(now: model.tick).menu)
            .task {
                if model.takeReopenWindow() {
                    try? await Task.sleep(for: .milliseconds(600))
                    model.windowRequested = true
                    openWindow(id: AppModel.boardWindowID)
                    try? await Task.sleep(for: .milliseconds(200))
                    WindowFront.raiseBoard()
                }
                guard let tab = model.takeReopenSettingsTab() else { return }
                try? await Task.sleep(for: .milliseconds(600))
                model.settingsTab = tab
                openSettings()
                try? await Task.sleep(for: .milliseconds(200))
                WindowFront.raiseSettings()
            }
    }
}

/// The panel, with Settings and the window wired to its buttons.
private struct PanelHost: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            PanelView(
                board: model.board(now: context.date), now: context.date, update: model.update,
                refreshing: model.refreshing,
                actions: model.actions(
                    openSettings: { openSettingsTab($0, model: model, openSettings) },
                    openWindow: { showWindow($0, model: model, openWindow) }))
        }
        .onAppear {
            model.panelOpen = true
            model.panelOpened()
        }
        .onDisappear { model.panelOpen = false }
    }
}

/// Settings on a tab, brought forward even if it's already open behind other apps.
@MainActor private func openSettingsTab(_ tab: SettingsTab, model: AppModel, _ openSettings: OpenSettingsAction) {
    model.settingsTab = tab
    openSettings()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { WindowFront.raiseSettings() }
}

/// The window on a repo and tab, brought forward (Chief Stew has no Dock icon, so macOS
/// wouldn't on its own).
@MainActor private func showWindow(_ selection: WindowSelection, model: AppModel, _ openWindow: OpenWindowAction) {
    model.windowSelection = selection
    model.windowRequested = true
    openWindow(id: AppModel.boardWindowID)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { WindowFront.raiseBoard() }
}

/// The window's content. SwiftUI may open or restore a `Window` scene by itself at launch; it's
/// only ever shown when asked for from the panel (or reopened after an update).
private struct BoardWindowHost: View {
    @Bindable var model: AppModel
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            BoardWindowView(
                repos: model.repoViews(now: context.date), selection: $model.windowSelection,
                now: context.date,
                actions: model.actions(
                    openSettings: { openSettingsTab($0, model: model, openSettings) },
                    openWindow: { showWindow($0, model: model, openWindow) }))
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(WindowAccessor { window in
            window.identifier = WindowFront.boardID
            window.isRestorable = false
            if !model.windowRequested { window.close() }
        })
        .onAppear { model.windowOpen = true }
        .onDisappear { model.windowOpen = false }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?
    private var sigterm: DispatchSourceSignal?

    /// `kill` / `pkill` (SIGTERM, as the installer sends) quits now: it removes the heartbeat, so
    /// emitters take notifications back at once, and exits. Not NSApp.terminate, which AppKit
    /// refuses while a sheet is open (e.g. the Add Repo wizard), leaving an update stuck.
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { Self.model?.stop() }
            exit(0)
        }
        source.resume()
        sigterm = source
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { Self.model?.stop() }
    }
}
