import APNS
import APNSCore
import BattleshipAPI
import Vapor
import VaporAPNS

/// A notification for one player about one game.
struct PushMessage: Sendable, Hashable {
    let title: String
    let body: String
    let gameID: UUID
}

struct PushTarget: Sendable, Hashable {
    let token: String
    let environment: PushEnvironment
}

protocol PushService: Sendable {
    /// Delivers `message` to each device. Returns the tokens Apple reported as no longer valid.
    func send(_ message: PushMessage, to targets: [PushTarget]) async -> [String]
}

/// Used when no APNs credentials are configured.
struct DisabledPushService: PushService {
    func send(_ message: PushMessage, to targets: [PushTarget]) async -> [String] { [] }
}

/// Sends alerts through Apple Push Notification service with token-based (.p8 key) authentication.
struct APNSPushService: PushService {
    /// Custom payload the app reads to open the right game when a notification is tapped.
    struct Payload: Codable, Sendable {
        let gameID: String
    }

    let application: Application
    let topic: String

    func send(_ message: PushMessage, to targets: [PushTarget]) async -> [String] {
        var invalidTokens: [String] = []
        for target in targets {
            var notification = APNSAlertNotification(
                alert: APNSAlertNotificationContent(title: .raw(message.title), body: .raw(message.body)),
                expiration: .timeIntervalSince1970InSeconds(Int(Date().addingTimeInterval(60 * 60 * 24).timeIntervalSince1970)),
                priority: .immediately,
                topic: topic,
                payload: Payload(gameID: message.gameID.uuidString),
                sound: .default,
                threadID: message.gameID.uuidString
            )
            // Newer news about the same game replaces older notifications on the lock screen.
            notification.collapseID = message.gameID.uuidString

            let container: APNSContainers.ID = target.environment == .production ? .production : .development
            do {
                try await application.apns.client(container).sendAlertNotification(notification, deviceToken: target.token)
            } catch let error as APNSError {
                if let reason = error.reason,
                   [.unregistered, .badDeviceToken, .deviceTokenNotForTopic].contains(reason) {
                    invalidTokens.append(target.token)
                } else {
                    application.logger.warning("APNs rejected a notification: \(error)")
                }
            } catch {
                application.logger.warning("Could not reach APNs: \(error)")
            }
        }
        return invalidTokens
    }
}
