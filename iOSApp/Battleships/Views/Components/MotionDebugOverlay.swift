import QuartzCore
import SwiftUI

/// Counts the timelines ticking right now. `LoopClock`, `OneShot`, `CuePlayer` (and the boards'
/// effects layer) register while their timeline is live and unregister when it pauses or leaves
/// the screen, through `motionBudgeted(isLive:)`. The debug overlay shows the count against the
/// per-screen budgets.
@MainActor
@Observable
final class MotionBudget {
    static let shared = MotionBudget()

    private(set) var liveTimelines = 0

    func register() {
        liveTimelines += 1
    }

    func unregister() {
        liveTimelines = max(0, liveTimelines - 1)
    }
}

extension View {
    /// Counts this view's timeline in `MotionBudget.shared` while it is on screen and `isLive`.
    func motionBudgeted(isLive: Bool) -> some View {
        modifier(MotionBudgeted(isLive: isLive))
    }
}

private struct MotionBudgeted: ViewModifier {
    let isLive: Bool
    @State private var isVisible = false
    @State private var isRegistered = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                sync()
            }
            .onDisappear {
                isVisible = false
                sync()
            }
            .onChange(of: isLive) { sync() }
    }

    private func sync() {
        let wanted = isVisible && isLive
        guard wanted != isRegistered else { return }
        isRegistered = wanted
        if wanted {
            MotionBudget.shared.register()
        } else {
            MotionBudget.shared.unregister()
        }
    }
}

/// Frame time and dropped frames over the last second (from a `CADisplayLink`), the thermal state,
/// the motion tier, the screen's refresh rate and the live timelines. Compiled into every build and
/// shown by `RootView` when `AppSettings.showsPerformanceOverlay`, so TestFlight testers can read it.
struct MotionDebugOverlay: View {
    @State private var sampler = FrameSampler()
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        let preferences = MotionPreferences.shared
        let budget = MotionBudget.shared
        VStack(alignment: .leading, spacing: 2) {
            Text(String(format: "%.1f ms avg · %.0f ms worst", sampler.averageMilliseconds, sampler.worstMilliseconds))
                .foregroundStyle(sampler.droppedFrames > 0 ? Theme.amber : .white)
            Text("dropped \(sampler.droppedFrames)/s · \(budget.liveTimelines) timelines")
            Text("\(tierName) tier · \(thermalName) · \(preferences.maxFramesPerSecond) Hz screen")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { sampler.start() }
        .onDisappear { sampler.stop() }
    }

    private var tierName: String {
        switch policy.tier {
        case .full: "full"
        case .reduced: "reduced"
        case .still: "still"
        }
    }

    private var thermalName: String {
        switch MotionPreferences.shared.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

/// Reads the display link once a frame and publishes a summary once a second, so the overlay
/// itself costs one redraw a second.
@MainActor
@Observable
final class FrameSampler {
    /// The average frame interval over the last second, in milliseconds.
    private(set) var averageMilliseconds: Double = 0
    /// The longest frame in the last second, in milliseconds.
    private(set) var worstMilliseconds: Double = 0
    /// Frames in the last second that took over 1.5× the display's interval.
    private(set) var droppedFrames = 0

    @ObservationIgnored private var target: FrameLinkTarget?
    @ObservationIgnored private var lastTimestamp: CFTimeInterval = 0
    @ObservationIgnored private var windowStart: CFTimeInterval = 0
    @ObservationIgnored private var frames = 0
    @ObservationIgnored private var worst: CFTimeInterval = 0
    @ObservationIgnored private var dropped = 0

    nonisolated init() {}

    func start() {
        guard target == nil else { return }
        let target = FrameLinkTarget { [weak self] link in
            self?.record(link)
        }
        target.start()
        self.target = target
    }

    func stop() {
        target?.stop()
        target = nil
        lastTimestamp = 0
    }

    private func record(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastTimestamp = now }
        guard lastTimestamp > 0 else {
            windowStart = now
            return
        }
        let interval = now - lastTimestamp
        let expected = link.duration > 0 ? link.duration : 1 / 60
        frames += 1
        worst = max(worst, interval)
        if interval > expected * 1.5 {
            dropped += 1
        }
        if now - windowStart >= 1 {
            averageMilliseconds = frames > 0 ? (now - windowStart) / Double(frames) * 1000 : 0
            worstMilliseconds = worst * 1000
            droppedFrames = dropped
            frames = 0
            worst = 0
            dropped = 0
            windowStart = now
        }
    }
}

/// The display link's target: an `NSObject` for the selector, on the main run loop.
@MainActor
private final class FrameLinkTarget: NSObject {
    private let onFrame: (CADisplayLink) -> Void
    private var link: CADisplayLink?

    init(onFrame: @escaping (CADisplayLink) -> Void) {
        self.onFrame = onFrame
        super.init()
    }

    func start() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        onFrame(link)
    }
}
