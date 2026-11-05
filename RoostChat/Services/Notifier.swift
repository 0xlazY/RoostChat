import Foundation
import UserNotifications

/// Local notifications for messages received while the app is running. Delivery
/// with the app closed would need APNs, a paid account and a push relay.
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called when the user taps a notification.
    var onOpen: ((ChatRoute) -> Void)?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            DebugLog.shared.add(.app, "Notification permission: \(granted ? "granted" : "not granted")\(error.map { " (\($0.localizedDescription))" } ?? "")")
        }
    }

    func authorizationSummary(_ completion: @escaping (String) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let text: String
            switch settings.authorizationStatus {
            case .authorized: text = "Allowed"
            case .denied: text = "Denied in iOS Settings"
            case .notDetermined: text = "Not asked yet"
            case .provisional: text = "Provisional"
            case .ephemeral: text = "Ephemeral"
            @unknown default: text = "Unknown"
            }
            DispatchQueue.main.async { completion(text) }
        }
    }

    func post(route: ChatRoute, sender: String, body: String, showPreview: Bool) {
        let content = UNMutableNotificationContent()
        content.title = route.title
        if route.kind == .room { content.subtitle = sender }
        content.body = showPreview ? body : "New message"
        content.sound = .default
        content.threadIdentifier = route.id
        content.userInfo = ["account": route.account, "peer": route.peer, "kind": route.kind.rawValue, "title": route.title]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { DebugLog.shared.add(.app, "Notification failed: \(error.localizedDescription)") }
        }
    }

    func postTest() {
        let content = UNMutableNotificationContent()
        content.title = "RoosterChat"
        content.body = "Notifications are working."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: trigger))
    }

    func setBadge(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if let account = info["account"] as? String, let peer = info["peer"] as? String, let title = info["title"] as? String {
            let kind = (info["kind"] as? String).flatMap(ConversationKind.init(rawValue:)) ?? .chat
            let route = ChatRoute(account: account, peer: peer, kind: kind, title: title)
            DispatchQueue.main.async { self.onOpen?(route) }
        }
        completionHandler()
    }
}
