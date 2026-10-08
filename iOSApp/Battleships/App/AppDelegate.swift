import AuthenticationServices
import UIKit
import UserNotifications

/// Owns the app model and handles the parts of the app lifecycle SwiftUI leaves to UIKit:
/// push notification registration, taps on notifications, and Sign in with Apple's credential state.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private(set) lazy var model: AppModel = {
        let settings = AppSettings()
        let feedback = CombinedFeedback([
            Haptics(isEnabled: { settings.hapticsEnabled }),
            SoundEffects(isEnabled: { settings.soundEnabled }),
        ])
        return AppModel(settings: settings, tokenStorage: KeychainTokenStorage(), feedback: feedback)
    }()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        Task { await PushPermission.registerIfAuthorized() }
        _ = NotificationCenter.default.addObserver(
            forName: ASAuthorizationAppleIDProvider.credentialRevokedNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAppleIDCredential() }
        }
        return true
    }

    /// Signs out if the player signed in with Apple and has since stopped using their Apple ID
    /// with the app. Apple asks apps to check this at launch and when the app returns.
    func checkAppleIDCredential() {
        guard let appleUserID = model.session.appleUserID, let token = model.session.token else { return }
        Task {
            if await AppleSignIn.hasStoppedUsingAppleID(appleUserID) {
                model.sessionDidExpire(rejectedToken: token)
            }
        }
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
