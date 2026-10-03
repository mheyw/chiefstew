import AppKit
import ChiefStewCore
@preconcurrency import UserNotifications
import os

/// Posts and withdraws notifications through UNUserNotificationCenter, and opens a notice's
/// target when it's clicked. What to post is decided by NotificationPlanner.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    enum Permission: Equatable { case unknown, granted, denied }

    private(set) var permission: Permission = .unknown
    /// Called with the clicked notice's ID and its `open` target, if any.
    var onClick: (_ id: String, _ open: String?) -> Void = { _, _ in }
    var onPermissionChange: (Permission) -> Void = { _ in }

    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "com.mheyw.chiefstew", category: "notify")

    override init() {
        super.init()
        center.delegate = self
    }

    /// Asks once (macOS shows its prompt the first time only), then reads the real setting.
    func requestPermission() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
        await refreshPermission()
    }

    func refreshPermission() async {
        let status = await center.notificationSettings().authorizationStatus
        let now: Permission =
            switch status {
            case .authorized, .provisional: .granted
            case .denied: .denied
            default: .unknown
            }
        if now != permission {
            permission = now
            log.info("notification permission: \(String(describing: now), privacy: .public)")
            onPermissionChange(now)
        }
    }

    func post(_ notice: Notice) {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = notice.isReminder || notice.passive ? nil : .default
        if notice.passive { content.interruptionLevel = .passive }
        content.threadIdentifier = "chiefstew"
        if let open = notice.open { content.userInfo = ["open": open] }
        center.add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)) {
            [log] error in
            if let error { log.error("post failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    func withdraw(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    // MARK: UNUserNotificationCenterDelegate

    /// A menu-bar app counts as active, so ask for the banner explicitly.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let id = response.notification.request.identifier
        let open = response.notification.request.content.userInfo["open"] as? String
        await MainActor.run { onClick(id, open) }
    }
}
