import AppKit
import os
import UserNotifications

private let notifierLog = Logger(subsystem: "com.dmschellaz.redline", category: "notifications")

final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let path = response.notification.request.content.userInfo["folder"] as? String else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
    }
}

@MainActor
enum Notifier {
    private static let delegate = NotificationDelegate()

    static func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error { notifierLog.error("Notification authorization failed: \(error.localizedDescription, privacy: .public)") }
            else if !granted { notifierLog.notice("Notifications are turned off for Redline") }
        }
    }

    static func post(title: String, body: String, folder: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let folder { content.userInfo = ["folder": folder.path] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)) { error in
            if let error { notifierLog.error("Couldn't post notification: \(error.localizedDescription, privacy: .public)") }
        }
    }
}
