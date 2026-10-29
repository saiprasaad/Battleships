import SwiftUI

/// The clock for a one-shot effect: a burst, confetti, a stamp, a counter. It starts on first
/// appearance, hands `content` the seconds elapsed (clamped to `duration`) and stops ticking once the
/// effect is over, so a finished effect costs nothing. In the still tier it hands `content` the end
/// state (`duration`) at once and never ticks.
///
/// `frameInterval` is the slowest the clock may tick; `nil` means every frame, capped at 60 a second
/// (ProMotion displays never run effects at 120). The reduced tier caps it at 30.
struct OneShotClock<Content: View>: View {
    let duration: TimeInterval
    let frameInterval: TimeInterval?
    let content: (TimeInterval) -> Content
    @State private var start = Date()
    @State private var isDone = false
    @Environment(\.motionPolicy) private var policy

    init(duration: TimeInterval, frameInterval: TimeInterval? = nil, @ViewBuilder content: @escaping (TimeInterval) -> Content) {
        self.duration = duration
        self.frameInterval = frameInterval
        self.content = content
    }

    var body: some View {
        let isStill = policy.loopsHoldStill
        let interval = Clocks.interval(frameInterval, for: policy)
        TimelineView(.animation(minimumInterval: interval, paused: isDone || isStill)) { timeline in
            content(isStill ? duration : min(duration, max(0, timeline.date.timeIntervalSince(start))))
        }
        .task {
            try? await Task.sleep(for: .seconds(max(0, duration)))
            isDone = true
        }
    }
}

/// A looping clock for the effects on one board, driven by its `FXClock`: `content` gets the board's
/// effect time, which stands still through a hit-stop and stretches through slow motion. It pauses in
/// the still tier. `frameInterval` works as it does for `OneShotClock`.
struct EffectTimeline<Content: View>: View {
    let clock: FXClock
    let frameInterval: TimeInterval?
    let content: (TimeInterval) -> Content
    @Environment(\.motionPolicy) private var policy

    init(clock: FXClock, frameInterval: TimeInterval? = nil, @ViewBuilder content: @escaping (TimeInterval) -> Content) {
        self.clock = clock
        self.frameInterval = frameInterval
        self.content = content
    }

    var body: some View {
        let interval = Clocks.interval(frameInterval, for: policy)
        TimelineView(.animation(minimumInterval: interval, paused: policy.loopsHoldStill)) { timeline in
            content(clock.time(at: timeline.date))
        }
    }
}

/// Frame caps shared by the clocks.
enum Clocks {
    /// Effects never run faster than 60 frames a second, or 30 in the reduced tier.
    static let effectsFrameInterval: TimeInterval = 1 / 60
    static let reducedFrameInterval: TimeInterval = 1 / 30

    /// The interval a clock asked for (or every frame), held to the policy's cap.
    static func interval(_ requested: TimeInterval?, for policy: MotionPolicy) -> TimeInterval {
        let wanted = requested ?? effectsFrameInterval
        return policy.tier == .full ? max(wanted, effectsFrameInterval) : max(wanted, reducedFrameInterval)
    }
}
