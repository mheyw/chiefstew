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
            MenuBarLabel(state: model.board(now: model.tick).menu)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

/// The panel, with the Settings window wired to the footer buttons.
private struct PanelHost: View {
    let model: AppModel
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            PanelView(
                board: model.board(now: context.date), now: context.date, update: model.update,
                actions: model.actions { tab in
                    model.settingsTab = tab
                    openSettings()
                    // Already open (perhaps behind other apps)? Bring it forward too.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { WindowFront.raiseSettings() }
                })
        }
        .onAppear { model.panelOpened() }
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
