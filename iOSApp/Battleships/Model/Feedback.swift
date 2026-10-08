import Foundation

/// Moments in a game that deserve tactile feedback.
enum FeedbackEvent: Sendable {
    case select
    case aim
    case place
    case invalid
    case fire
    case miss
    case hit
    case sunk
    case victory
    case defeat
}

/// Plays feedback for game events. The app uses haptics; tests use a recorder.
@MainActor
protocol FeedbackPlayer: AnyObject {
    func play(_ event: FeedbackEvent)
}

/// Turns any error into a sentence fit for an alert.
extension Error {
    var userMessage: String {
        if let localized = self as? any LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "Something went wrong. Please try again."
    }
}
