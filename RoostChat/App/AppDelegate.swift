import UIKit

/// Receives the APNs device token, which iOS only delivers to an app delegate.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var onToken: ((Data) -> Void)?
    static var onTokenError: ((String) -> Void)?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Self.onToken?(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Self.onTokenError?(error.localizedDescription)
    }
}
