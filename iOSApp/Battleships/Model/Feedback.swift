import Foundation

/// Moments in a game that deserve feedback: a picture, a rumble and a sound, all from one event.
enum FeedbackEvent: CaseIterable, Sendable {
    /// A control chosen, e.g. a row in a list.
    case select
    /// A cell lined up on the target board.
    case aim
    /// A ship put down on the deploy board.
    case place
    /// Something the player can't do: a cell already fired at, a ship off the board.
    case invalid
    /// The player's gun fires.
    case fire
    /// The opponent fired at the player's fleet.
    case incoming
    /// A shell falls into open water (played when it lands).
    case miss
    /// A shell strikes a ship (played when it lands).
    case hit
    /// A shell finishes a ship (played when it lands).
    case sunk
    /// The game is won.
    case victory
    /// The game is lost.
    case defeat
    /// A ship picked up on the deploy board.
    case lift
    /// A ship turned on the deploy board.
    case rotate
    /// The fleet departs: deploy confirmed.
    case castOff
    /// The enemy shell is coming: a 0.45 s rising whistle, played at the start of the telegraph.
    case whistle
    /// It's the player's turn.
    case turnSting
    /// The SUNK stamp slams down.
    case stamp
    /// The last shell of the game, in slow motion.
    case finalBlow
    /// An opponent was found for an online game.
    case matchFound
    /// BATTLE STATIONS: a battle begins.
    case opening
    /// A toast with good news.
    case toastSuccess
    /// A toast with bad news.
    case toastError
    /// A counter step; very quiet, short.
    case tick
    /// Headline: one ship left.
    case lastShip
    /// A hit streak chip appears.
    case streak
}

/// Plays feedback for game events. The app uses haptics and sound; tests use a recorder.
@MainActor
protocol FeedbackPlayer: AnyObject {
    func play(_ event: FeedbackEvent)
    /// Starts or stops the ambient bed. Only the sound stage has one; other players ignore it.
    func setAmbience(_ isOn: Bool)
}

extension FeedbackPlayer {
    func setAmbience(_ isOn: Bool) {}
}

/// Plays each event on several players, e.g. haptics and sound.
@MainActor
final class CombinedFeedback: FeedbackPlayer {
    private let players: [any FeedbackPlayer]

    init(_ players: [any FeedbackPlayer]) {
        self.players = players
    }

    func play(_ event: FeedbackEvent) {
        for player in players {
            player.play(event)
        }
    }

    func setAmbience(_ isOn: Bool) {
        for player in players {
            player.setAmbience(isOn)
        }
    }
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
