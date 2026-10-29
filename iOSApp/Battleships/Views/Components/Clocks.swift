import SwiftUI

/// The clock for a one-shot effect: a burst, confetti, a stamp, a counter. It starts on first
/// appearance, hands `content` the seconds elapsed (clamped to `duration`) and stops ticking once the
/// effect is over, so a finished effect costs nothing. In the still tier it hands `content` the end
/// state (`duration`) at once and never ticks.
///
/// `frameInterval` is the slowest the clock may tick; `nil` means every frame, capped at 60 a second
/// (ProMotion displays never run effects at 120). The reduced tier caps it at 30.
///
/// Prefer `OneShot` for new code: it runs from a trigger, hands a 0…1 progress and replays.
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
        let isLive = !isDone && !isStill
        TimelineView(.animation(minimumInterval: interval, paused: !isLive)) { timeline in
            content(isStill ? duration : min(duration, max(0, timeline.date.timeIntervalSince(start))))
        }
        .motionBudgeted(isLive: isLive)
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
        let isLive = !policy.loopsHoldStill
        TimelineView(.animation(minimumInterval: interval, paused: !isLive)) { timeline in
            content(clock.time(at: timeline.date))
        }
        .motionBudgeted(isLive: isLive)
    }
}

/// Runs a timeline from a change of `trigger` for `duration` seconds, hands `content` a 0…1 progress
/// through `curve`, then pauses itself, so a finished effect costs nothing. `playsOnAppear` also runs
/// it once when the view appears. Policy-aware: the reduced tier shortens it (`policy.duration`), and
/// the still tier or frozen clocks show the final frame at once. Content gets 1 while idle, too, so
/// a view reads "progress 1" as "at rest".
struct OneShot<Trigger: Equatable, Content: View>: View {
    let trigger: Trigger
    let duration: TimeInterval
    let curve: @Sendable (Double) -> Double
    let playsOnAppear: Bool
    let content: (Double) -> Content
    @State private var start: Date?
    @State private var isDone = true
    @Environment(\.motionPolicy) private var policy

    init(
        trigger: Trigger,
        duration: TimeInterval,
        curve: @escaping @Sendable (Double) -> Double = Motion.easeOut,
        playsOnAppear: Bool = false,
        @ViewBuilder content: @escaping (Double) -> Content
    ) {
        self.trigger = trigger
        self.duration = duration
        self.curve = curve
        self.playsOnAppear = playsOnAppear
        self.content = content
    }

    var body: some View {
        let isLive = start != nil && !isDone && !policy.holdsStill
        TimelineView(.animation(minimumInterval: policy.effectsInterval, paused: !isLive)) { timeline in
            content(curve(progress(at: timeline.date)))
        }
        .motionBudgeted(isLive: isLive)
        .onAppear {
            if playsOnAppear {
                play()
            }
        }
        .onChange(of: trigger) { play() }
        .task(id: start) {
            guard start != nil else { return }
            do {
                try await Task.sleep(for: .seconds(policy.duration(duration)))
            } catch {
                return   // replayed, or gone from the screen
            }
            isDone = true
        }
    }

    private func play() {
        if policy.holdsStill {
            start = nil
            isDone = true
        } else {
            start = Date()
            isDone = false
        }
    }

    /// 0…1 through the run; 1 at rest, in the still tier and with frozen clocks.
    private func progress(at date: Date) -> Double {
        guard let start, !policy.holdsStill else { return 1 }
        let length = policy.duration(duration)
        guard length > 0 else { return 1 }
        return min(1, max(0, date.timeIntervalSince(start) / length))
    }
}

/// The kinds of looping decoration, each with its own frame rate from the policy.
enum MotionLoop {
    /// The sea: 24 frames a second, 12 in the reduced tier.
    case water
    /// Radar, waves, halos: 30 a second, 15 reduced.
    case ambient
    /// Backdrop drift, bobbing ships, smoke: 20 a second, 10 reduced.
    case scenery
    /// Flames and other burning loops: the effects rate, held to 24 a second.
    case effects
}

/// One timeline for a looping subtree, at the frame interval the policy gives this kind of loop,
/// handing `content` the time in seconds, or `nil` when the loop should hold still (draw the pretty
/// phase then). `isLive` pauses it when there is nothing to animate, e.g. no fire burning.
/// Generalises the boards' `FlameClock`.
struct LoopClock<Content: View>: View {
    /// `LoopClock(loop: .effects) { … }` reads as the spec writes it; the cases live in `MotionLoop`
    /// so they resolve before `Content` is inferred.
    typealias Loop = MotionLoop

    let loop: Loop
    let isLive: Bool
    let content: (Double?) -> Content
    @Environment(\.motionPolicy) private var policy

    init(loop: Loop, isLive: Bool = true, @ViewBuilder content: @escaping (Double?) -> Content) {
        self.loop = loop
        self.isLive = isLive
        self.content = content
    }

    var body: some View {
        let interval = loopInterval
        let isRunning = isLive && interval != nil && !policy.holdsStill
        TimelineView(.animation(minimumInterval: interval ?? Clocks.reducedFrameInterval, paused: !isRunning)) { timeline in
            content(isRunning ? Motion.seconds(timeline.date) : nil)
        }
        .motionBudgeted(isLive: isRunning)
    }

    /// The policy's interval for this loop, or nil when it holds still.
    private var loopInterval: TimeInterval? {
        switch loop {
        case .water: policy.waterInterval
        case .ambient: policy.ambientInterval
        case .scenery: policy.sceneryInterval
        case .effects: policy.tier == .still ? nil : max(policy.effectsInterval, Clocks.flameFrameInterval)
        }
    }
}

/// Frame caps shared by the clocks.
enum Clocks {
    /// Effects never run faster than 60 frames a second, or 30 in the reduced tier.
    static let effectsFrameInterval: TimeInterval = 1 / 60
    static let reducedFrameInterval: TimeInterval = 1 / 30
    /// Burning loops (flames, embers) are held to 24 frames a second: flicker reads the same and
    /// a board full of fires costs less.
    static let flameFrameInterval: TimeInterval = 1 / 24

    /// The interval a clock asked for (or every frame), held to the policy's cap.
    static func interval(_ requested: TimeInterval?, for policy: MotionPolicy) -> TimeInterval {
        let wanted = requested ?? effectsFrameInterval
        return policy.tier == .full ? max(wanted, effectsFrameInterval) : max(wanted, reducedFrameInterval)
    }
}
