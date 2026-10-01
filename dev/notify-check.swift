// M2 spike: can an ad-hoc-signed SwiftPM .app post through UNUserNotificationCenter?
// Built into a throwaway bundle by dev/notify-check.sh; not part of the app.

import AppKit
import UserNotifications

final class Delegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ note: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            print("authorization granted=\(granted) error=\(String(describing: error))")
            center.getNotificationSettings { s in
                print("settings authorization=\(s.authorizationStatus.rawValue) alert=\(s.alertSetting.rawValue)")
                let content = UNMutableNotificationContent()
                content.title = "174 needs you"
                content.body = "Plan gate — checkout_flow (Chief Stew notification check)"
                content.sound = .default
                content.threadIdentifier = "gate-174-plan"
                let request = UNNotificationRequest(
                    identifier: "check-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
                center.add(request) { error in
                    print("add error=\(String(describing: error))")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
                }
            }
        }
    }

    // Show it even though the app is frontmost-ish (menu-bar apps count as active).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
