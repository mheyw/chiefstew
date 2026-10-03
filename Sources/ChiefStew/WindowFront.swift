import AppKit
import SwiftUI

/// Chief Stew has no Dock icon (LSUIElement), and macOS doesn't bring such an app's windows
/// forward on its own: Settings would open behind whatever app you're in. These bring it to the
/// front, on the current desktop.
enum WindowFront {
    static let settingsID = NSUserInterfaceItemIdentifier("chiefstew.settings")
    static let boardID = NSUserInterfaceItemIdentifier("chiefstew.board")

    @MainActor static func raise(_ window: NSWindow?) {
        guard let window else { return }
        window.collectionBehavior.insert(.moveToActiveSpace)
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()  // in front even if activation is declined
    }

    /// The Settings window, if it's open (it may be hidden behind other apps).
    @MainActor static func raiseSettings() {
        raise(NSApp.windows.first { $0.identifier == settingsID })
    }

    /// The Chief Stew window, if it's open.
    @MainActor static func raiseBoard() {
        raise(NSApp.windows.first { $0.identifier == boardID })
    }
}

/// Hands a SwiftUI view its NSWindow once it's in one: used to tag and raise Settings.
struct WindowAccessor: NSViewRepresentable {
    var onWindow: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = AccessorView()
        view.onWindow = onWindow
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class AccessorView: NSView {
        var onWindow: (@MainActor (NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            let callback = onWindow
            DispatchQueue.main.async { callback?(window) }
        }
    }
}
