import UIKit
import UserNotifications

/// Asking for notification permission at a moment that makes sense: right after the player starts
/// their first online game, when "tell me when it's my turn" is obviously useful.
@MainActor
enum PushPermission {
    /// Asks once. Later calls do nothing; the player can change their mind in Settings.
    static func requestIfNeeded(settings: AppSettings) async {
        guard !settings.hasAskedForNotifications else { return }
        await request(settings: settings)
    }

    static func request(settings: AppSettings) async {
        settings.hasAskedForNotifications = true
        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        if granted {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Re-registers on launch if permission was already given, so the server has a fresh token.
    static func registerIfAuthorized() async {
        switch await status() {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        default:
            break
        }
    }

    static func status() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
