import ChiefStewCore
import Foundation

/// Brings forward the Terminal or iTerm tab running a session, found by its terminal device.
/// Uses AppleScript, so macOS asks the owner once to let Chief Stew control that app; if they
/// say no (or the tab has closed), `select` returns false and the caller just activates the app.
enum TerminalTab {
    static func supports(_ bundleID: String) -> Bool { scripts[bundleID] != nil }

    static func select(tty: String, in bundleID: String) async -> Bool {
        // The tty comes from an event file: only a plain device name, passed as an argument
        // to the script, never spliced into it.
        guard let script = scripts[bundleID],
            tty.range(of: #"^ttys[0-9]{1,4}$"#, options: .regularExpression) != nil,
            // Generous: the first time, this waits while the owner answers the permission prompt.
            let r = try? await CommandRunner.run("/usr/bin/osascript", ["-e", script, "/dev/\(tty)"], timeout: 120)
        else { return false }
        return r.exitCode == 0 && String(decoding: r.stdout, as: UTF8.self).hasPrefix("ok")
    }

    private static let scripts: [String: String] = [
        "com.apple.Terminal": """
        on run argv
          tell application id "com.apple.Terminal"
            repeat with w in windows
              repeat with t in tabs of w
                if tty of t is item 1 of argv then
                  set selected of t to true
                  set index of w to 1
                  activate
                  return "ok"
                end if
              end repeat
            end repeat
          end tell
          return "missing"
        end run
        """,
        "com.googlecode.iterm2": """
        on run argv
          tell application id "com.googlecode.iterm2"
            repeat with w in windows
              repeat with t in tabs of w
                repeat with s in sessions of t
                  if tty of s is item 1 of argv then
                    select w
                    tell t to select
                    tell s to select
                    activate
                    return "ok"
                  end if
                end repeat
              end repeat
            end repeat
          end tell
          return "missing"
        end run
        """,
    ]
}
