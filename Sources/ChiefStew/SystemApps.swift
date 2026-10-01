import AppKit
import ServiceManagement

/// Apps "Open worktree" can use, filtered to what's installed. Finder is the default.
enum WorktreeApps {
    static let known: [(name: String, bundleID: String)] = [
        ("Visual Studio Code", "com.microsoft.VSCode"),
        ("Cursor", "com.todesktop.230313mzl4w4u92"),
        ("Zed", "dev.zed.Zed"),
        ("Xcode", "com.apple.dt.Xcode"),
        ("Sublime Text", "com.sublimetext.4"),
        ("Nova", "com.panic.Nova"),
        ("Terminal", "com.apple.Terminal"),
        ("iTerm", "com.googlecode.iterm2"),
        ("Ghostty", "com.mitchellh.ghostty"),
        ("Warp", "dev.warp.Warp-Stable"),
    ]

    static func installed() -> [(name: String, bundleID: String)] {
        known.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    /// Opens `folder` in the app with `bundleID`, or Finder when nil or not installed.
    /// Only plain folders: a path that is a bundle (an .app) or a file is revealed in Finder
    /// instead, so a path from an event can never launch anything (review: event-path-launches-apps).
    @MainActor static func open(_ folder: String, with bundleID: String?) {
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir) else { return }
        guard isDir.boolValue, !NSWorkspace.shared.isFilePackage(atPath: folder) else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        guard let bundleID,
            let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else {
            NSWorkspace.shared.open(url)
            return
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Launch at login through SMAppService (macOS 13+). Registers the running bundle's path, so
/// turn it on from the installed copy in /Applications (M3), not from build/.
enum LaunchAtLogin {
    static var isOn: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }

    static var isInstalled: Bool { Bundle.main.bundlePath.hasPrefix("/Applications/") }
}
