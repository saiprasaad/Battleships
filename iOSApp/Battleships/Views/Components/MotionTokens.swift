import SwiftUI

/// The named curves every animation in the app uses, derived from the same numbers as `Timing`.
/// Feature code names a token and never writes an inline spring or duration; a new curve is added
/// here by the foundation owner. `Motion` is the clock-arithmetic enum in Ocean.swift.
extension Motion {
    enum Curve {
        static let press    = Animation.spring(duration: 0.12, bounce: 0.20)
        static let release  = Animation.spring(duration: 0.30, bounce: 0.35)
        static let snap     = Animation.spring(duration: 0.30, bounce: 0.20)   // aim moves, chips
        static let settle   = Animation.spring(duration: 0.50, bounce: 0.35)   // things landing
        static let slam     = Animation.spring(duration: 0.40, bounce: 0.45)   // brackets, stamps
        static let heavy    = Animation.spring(duration: 0.60, bounce: 0.15)   // cards, boards
        static let list     = Animation.spring(duration: 0.45, bounce: 0.22)
        static let enter    = Animation.spring(duration: 0.55, bounce: 0.25)
        static let lift     = Animation.spring(duration: 0.18, bounce: 0.25)
        static let drop     = Animation.spring(duration: 0.22, bounce: 0.30)
        static let rotate   = Animation.spring(duration: 0.38, bounce: 0.35)
        static let move     = Animation.spring(duration: 0.45, bounce: 0.25)
        static let depart   = Animation.easeIn(duration: 0.50)
        static let counter  = Animation.spring(duration: 0.35, bounce: 0)
        static let float    = Animation.easeOut(duration: 1.2)
        static let toast    = Animation.spring(duration: 0.45, bounce: 0.25)
        static let dismiss  = Animation.easeIn(duration: 0.18)
        static let phase    = Animation.easeInOut(duration: 0.30)
        static let state    = Animation.easeInOut(duration: 0.30)
        static let fade     = Animation.easeInOut(duration: 0.35)
        static let wipe     = Animation.easeOut(duration: 0.45)
        static let sail     = Animation.easeOut(duration: 1.2)
        static let reduced  = Animation.easeInOut(duration: 0.20)   // what every curve becomes under the reduced/still tiers
    }
}

extension Animation {
    /// The animation to use under `policy`: itself in the full tier, `Motion.Curve.reduced` otherwise.
    func policy(_ policy: MotionPolicy) -> Animation { policy.tier == .full ? self : Motion.Curve.reduced }
}
