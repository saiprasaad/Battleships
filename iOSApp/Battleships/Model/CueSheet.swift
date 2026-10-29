import Foundation

// Foundation only, so the model layer and the Linux compile check can read it: the choreography of a
// set piece as data. `CuePlayer` (Views/Components/CuePlayer.swift) plays a sheet on screen.

/// One beat of a set piece: its name, when it starts (seconds from the start of its sheet) and how
/// long it runs. A beat with no duration is a moment: a sound, a haptic, a state change.
struct Cue: Hashable, Sendable {
    let name: String
    let start: TimeInterval
    let duration: TimeInterval

    init(name: String, start: TimeInterval, duration: TimeInterval = 0) {
        self.name = name
        self.start = max(0, start)
        self.duration = max(0, duration)
    }

    /// When the cue is over.
    var end: TimeInterval { start + duration }
}

/// Easing for progress values, 0…1 in and 0…1 out. Foundation only, so a cue sheet's frames can use
/// it on the model side; `Motion.easeOut` in the views is the same curve.
enum Easing {
    static func linear(_ progress: Double) -> Double {
        clamp(progress)
    }

    /// Fast out, slow in: `1 - (1 - x)³`, the curve of `Motion.easeOut`.
    static func easeOut(_ progress: Double) -> Double {
        let x = clamp(progress)
        return 1 - (1 - x) * (1 - x) * (1 - x)
    }

    static func easeIn(_ progress: Double) -> Double {
        let x = clamp(progress)
        return x * x * x
    }

    static func easeInOut(_ progress: Double) -> Double {
        let x = clamp(progress)
        return x * x * (3 - 2 * x)
    }

    static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

/// The choreography of a set piece as a value: named cues on one timeline `total` seconds long. A
/// `CuePlayer` plays it from a trigger and hands its content a `Frame` per tick; the frame answers
/// how far each cue has got. Being a plain value it can sit in a `@State` default or a `static let`.
struct CueSheet: Equatable, Sendable {
    /// In playing order: by start, then as given.
    let cues: [Cue]
    /// How long the whole sheet runs. Cues may end before it; the player finishes at `total`.
    let total: TimeInterval

    init(_ cues: [Cue], total: TimeInterval) {
        self.cues = cues.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)
        self.total = max(0, total)
    }

    /// A sheet exactly as long as its last cue.
    init(_ cues: [Cue]) {
        self.init(cues, total: cues.map(\.end).max() ?? 0)
    }

    /// The first cue of that name.
    func cue(_ name: String) -> Cue? {
        cues.first { $0.name == name }
    }

    /// The sheet `elapsed` seconds in. `collapsed` (the policy's `collapsesSequences`) lands the
    /// frame on the end state: every progress reads 1 and nothing is active.
    func frame(at elapsed: TimeInterval, collapsed: Bool) -> Frame {
        Frame(elapsed: collapsed ? total : max(0, elapsed), total: total, collapsed: collapsed, cues: cues)
    }

    /// Where every cue is at one moment.
    struct Frame: Sendable {
        let elapsed: TimeInterval
        let total: TimeInterval
        /// `policy.collapsesSequences`: everything reads 1.
        let collapsed: Bool
        let cues: [Cue]

        /// How far `name` has got, 0…1 through `curve`. `index` and `stagger` offset the start for
        /// the `index`th of several things on one cue (rows, letters, ships), each with the cue's
        /// duration. 0 for a cue the sheet doesn't have; 1 for everything under collapse.
        func progress(
            _ name: String,
            index: Int = 0,
            stagger: TimeInterval = 0,
            curve: (Double) -> Double = Easing.easeOut
        ) -> Double {
            if collapsed { return 1 }
            guard let cue = cue(name) else { return 0 }
            let start = cue.start + Double(max(0, index)) * stagger
            let raw: Double
            if cue.duration > 0 {
                raw = Easing.clamp((elapsed - start) / cue.duration)
            } else {
                raw = elapsed >= start ? 1 : 0
            }
            return curve(raw)
        }

        /// Whether `name` is running right now (never under collapse).
        func isActive(_ name: String) -> Bool {
            guard !collapsed, let cue = cue(name) else { return false }
            return cue.start <= elapsed && elapsed < cue.end
        }

        /// Whether `name` has begun (always, under collapse).
        func hasStarted(_ name: String) -> Bool {
            if collapsed { return true }
            guard let cue = cue(name) else { return false }
            return elapsed >= cue.start
        }

        /// Whether `name` is over (always, under collapse).
        func hasEnded(_ name: String) -> Bool {
            if collapsed { return true }
            guard let cue = cue(name) else { return false }
            return elapsed >= cue.end
        }

        /// Whether the whole sheet is over.
        var isFinished: Bool {
            collapsed || elapsed >= total
        }

        private func cue(_ name: String) -> Cue? {
            cues.first { $0.name == name }
        }
    }
}
