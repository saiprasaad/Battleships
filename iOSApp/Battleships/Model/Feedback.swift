import Foundation

/// Moments in a game that deserve feedback: a picture, a rumble and a sound, all from one event.
/// Every case has a sound (`SoundSynthesis`) and a haptic score (`HapticScore`), unless the score
/// lists it in `HapticScore.silentEvents` (loops are sound only).
enum FeedbackEvent: CaseIterable, Sendable {
    /// A control chosen, e.g. a row in a list; a placement ghost snapping; a toggle flipped.
    case select
    /// A cell lined up on the target board.
    case aim
    /// A ship put down on the deploy board.
    case place
    /// Something the player can't do: a cell already fired at, a ship off the board.
    case invalid
    /// The player's gun fires. Its rumble lasts exactly the shell's flight.
    case fire
    /// The opponent fired at the player's fleet: a distant gun.
    case incoming
    /// A shell falls into open water (played when it lands; `variation.pan` from the column).
    case miss
    /// A shell strikes a ship (played when it lands). `variation.isMine == false` is their shell on your hull.
    case hit
    /// A shell finishes a ship (played when it lands). `isMine == false` is your ship; `isFinal` is the finale.
    case sunk
    /// The game is won: the fanfare.
    case victory
    /// The game is lost: the lament.
    case defeat
    /// A ship picked up on the deploy board.
    case lift
    /// A ship turned on the deploy board.
    case rotate
    /// The fleet departs: deploy confirmed.
    case castOff
    /// The enemy shell is coming: a 0.45 s whistle, played at the start of the telegraph.
    case whistle
    /// It's the player's turn: a two-note chime.
    case turnSting
    /// The SUNK stamp slams down.
    case stamp
    /// The last shell of the game, in slow motion.
    case finalBlow
    /// An opponent was found for an online game.
    case matchFound
    /// BATTLE STATIONS: a battle begins; the title slams down.
    case opening
    /// A toast with good news; sign-in.
    case toastSuccess
    /// A toast with bad news.
    case toastError
    /// A counter step; very quiet, short.
    case tick
    /// Headline: one ship left. `variation.isMine` says whose: yours (down) or theirs (up).
    case lastShip
    /// A hit streak chip appears (`variation.count` is the streak).
    case streak
    /// The fleet shuffled: a staggered sweep of taps, one per ship (`variation.count`).
    case shuffle
    /// Their shell on your hull: duller and longer than `hit`, panned the mirrored way.
    case hitOwn
    /// Your ship goes down: `sunk` through a low-pass, with the hull's groan.
    case sunkOwn
    /// A splash right beside a ship: a taller column.
    case nearMiss
    /// The turn passes to the opponent: a soft low tick.
    case theirTurn
    /// A loop while any own ship burns. Sound only: `setLoop(.burning, isOn:)`, never `play`.
    case burning
    /// A firework bursts at its apex (victory ceremony; at most two a second).
    case firework
    /// The one lightning strike of a defeat.
    case thunder
    /// A tab switch, a sheet opening or closing, a row tap: a soft tick.
    case navigate
}

/// How one play of an event differs from the last: level, place, take, side, finale, repeats and
/// when it should land. The players read what they can use and ignore the rest.
struct FeedbackVariation: Sendable, Equatable {
    /// Scales the haptic intensity and the sound level, 0…1.
    var intensity: Double = 1
    /// −1 (left) … 1 (right): from the column on the target board, mirrored on the home board.
    var pan: Double = 0
    /// Picks the pre-rendered take; 0 cycles through them.
    var seed: Int = 0
    /// Whose side it happened on: `hit` on the enemy vs `hitOwn`, the direction of `lastShip`.
    var isMine = true
    /// The finale: the slow explosion and the drawn-out haptic.
    var isFinal = false
    /// Repeats: one tap per ship for `shuffle`, the streak length for `streak`.
    var count = 1
    /// Seconds to wait before the sound and the haptic start, scheduled on the engines' own
    /// clocks so a landing meets its frame whatever the main thread is doing.
    var delay: TimeInterval = 0

    static let `default` = FeedbackVariation()
}

/// Where the player is, for the ambient bed under everything (the sound stage's business only).
enum AmbientScene: Equatable, Sendable {
    /// Nothing: the background, ambience turned off, or a screen without a sea.
    case none
    case welcome
    case lobby
    case placement
    case battle(BattleController.Mood)
    case gameOver(didWin: Bool)
}

/// Plays feedback for game events. The app uses haptics and sound; tests use a recorder.
/// `play(_:)` is the one call every player must answer; the rest have no-op defaults, so a
/// player only overrides what it can do.
@MainActor
protocol FeedbackPlayer: AnyObject {
    func play(_ event: FeedbackEvent)
    /// Plays `event` shaped by `variation`.
    func play(_ event: FeedbackEvent, variation: FeedbackVariation)
    /// A battle or placement appeared: engines start, so the first cue has no latency.
    func prepare()
    /// It disappeared, or the app went to the background: engines stop, loops and the bed fall silent.
    func rest()
    /// Starts or stops a looping event (`.burning`).
    func setLoop(_ event: FeedbackEvent, isOn: Bool)
    /// Moves the ambient bed to `scene`; `.none` fades it out.
    func setAmbientScene(_ scene: AmbientScene)
}

extension FeedbackPlayer {
    func play(_ event: FeedbackEvent, variation: FeedbackVariation) { play(event) }
    func prepare() {}
    func rest() {}
    func setLoop(_ event: FeedbackEvent, isOn: Bool) {}
    func setAmbientScene(_ scene: AmbientScene) {}

    /// The old on/off switch: the lobby's sea when on, silence when off.
    func setAmbience(_ isOn: Bool) {
        setAmbientScene(isOn ? .lobby : .none)
    }
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

    func play(_ event: FeedbackEvent, variation: FeedbackVariation) {
        for player in players {
            player.play(event, variation: variation)
        }
    }

    func prepare() {
        for player in players {
            player.prepare()
        }
    }

    func rest() {
        for player in players {
            player.rest()
        }
    }

    func setLoop(_ event: FeedbackEvent, isOn: Bool) {
        for player in players {
            player.setLoop(event, isOn: isOn)
        }
    }

    func setAmbientScene(_ scene: AmbientScene) {
        for player in players {
            player.setAmbientScene(scene)
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
