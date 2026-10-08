import UIKit
import UserNotifications

/// Owns the app model and handles the parts of the app lifecycle SwiftUI leaves to UIKit:
/// push notification registration and taps on notifications.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private(set) lazy var model: AppModel = {
        let settings = AppSettings()
        let haptics = Haptics(isEnabled: { settings.hapticsEnabled })
        return AppModel(settings: settings, tokenStorage: KeychainTokenStorage(), feedback: haptics)
    }()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { await PushPermission.registerIfAuthorized() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await model.didRegisterForPushNotifications(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: any Error) {
        // Push needs the Push Notifications capability (and a paid developer account). Everything
        // else works without it: games still update live while the app is open.
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let gameID = Self.gameID(in: notification.request.content.userInfo)
        let isOnScreen = await MainActor.run { gameID != nil && self.model.visibleGameID == gameID }
        // The battle screen already shows what happened; don't repeat it in a banner.
        return isOnScreen ? [] : [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        guard let gameID = Self.gameID(in: response.notification.request.content.userInfo) else { return }
        await MainActor.run { self.model.open(.online(gameID)) }
    }

    private nonisolated static func gameID(in userInfo: [AnyHashable: Any]) -> UUID? {
        (userInfo["gameID"] as? String).flatMap(UUID.init(uuidString:))
    }
}
