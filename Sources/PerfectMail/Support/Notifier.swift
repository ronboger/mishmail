import Foundation
import AppKit
import UserNotifications

/// Native notifications for new mail and due reminders, plus the dock badge.
enum Notifier {
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { _, _ in }
    }

    static func notify(title: String, body: String, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static func setBadge(_ count: Int) {
        DispatchQueue.main.async {
            // Classic Dock badge: always works, no permission needed.
            NSApplication.shared.dockTile.badgeLabel = count > 0 ? String(count) : ""
        }
        // Notification-center badge: the channel newer system UI (e.g. the
        // Cmd-Tab switcher) reads. Needs the .badge grant requested at
        // launch; harmless no-op if the user declined notifications.
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
    }
}
