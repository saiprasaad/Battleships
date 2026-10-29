import Foundation

/// Every duration the visuals, the sound synthesis (baked silence), the haptic score (relative times),
/// the battle controller (scheduling) and the tests share, so picture, rumble and sound land on the
/// same frame. Foundation only, so the model layer and the Linux compile check can read it. Feature
/// code names a token here and never writes its own duration literal; a new token is added here by
/// the foundation owner.
enum Timing {
    // The shot
    static let shellFlight: TimeInterval = 0.42      // fire → landing; replaces SoundSynthesis.flightTime and ImpactBurst.flightTime
    static let apexHold: TimeInterval = 0.55 * shellFlight   // online: the shell waits here until the server answers
    static let apexTimeout: TimeInterval = 2.0       // then the readout says TRANSMITTING and the shell dims
    static let hitStop: TimeInterval = 0.07
    static let sunkHitStop: TimeInterval = 0.09
    static let finalHitStop: TimeInterval = 0.14
    static let impact: TimeInterval = 1.15           // the burst
    static let impactLinger: TimeInterval = 1.25     // when the controller forgets the effect (was impactDuration 1.2)
    static let secondaryStep: TimeInterval = 0.12    // chain detonation spacing (≥ 120 ms: never an 11 Hz strip)
    static let sinking: TimeInterval = 3.2
    static let sunkStamp: TimeInterval = 1.4         // after landing
    static let stampHold: TimeInterval = 1.6
    static let listStart: TimeInterval = 0.35
    static let whistle: TimeInterval = 0.45          // telegraph length, the last part of the enemy's pause
    static let incomingStreak: TimeInterval = 0.12
    static let turnSting: TimeInterval = 0.6         // after the enemy's landing
    static let calloutHold: TimeInterval = 2.4
    static let bannerHold: TimeInterval = 2.4
    // The finale
    static let finalSlowMotion: TimeInterval = 0.6
    static let finalTimeScale: Double = 0.35
    static let fleetSurfaceStart: TimeInterval = 1.6
    static let finaleCard: TimeInterval = 2.6        // overlay starts fading in (0.35 s) after the last landing
    static let finaleCardReduced: TimeInterval = 0.9 // Reduce Motion / VoiceOver: today's delay
    // Openings and deploy
    static let opening: TimeInterval = 1.5
    static let matchFound: TimeInterval = 1.2
    static let openingSkip: TimeInterval = 0.2
    static let deployLock: TimeInterval = 0.45
    static let deployCastOff: TimeInterval = 0.56
    static let deployReduced: TimeInterval = 0.25
    // Attention
    static let idleCue: TimeInterval = 15            // headline breathes, reticle pings once
    static let idleTier: TimeInterval = 45           // motion drops to the reduced tier
    static let ambientIdleFade: TimeInterval = 75    // the bed fades out
    static let catchUpStep: TimeInterval = 0.35      // while-you-were-away shots

    enum Stagger {
        static let row: TimeInterval = 0.035
        static let ship: TimeInterval = 0.045
        static let block: TimeInterval = 0.10
        static let letter: TimeInterval = 0.06
        static let surfacing: TimeInterval = 0.12
        static let fleetFate: TimeInterval = 0.15
        static let maxItems = 10
    }
}
