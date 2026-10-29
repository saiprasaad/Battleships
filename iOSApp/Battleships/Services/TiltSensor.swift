import CoreMotion
import Observation
import SwiftUI

/// The device's tilt, −1…1 per axis, low-passed, for backdrops that follow the hand (Welcome, the
/// lobby hero and the Game Over scrim; never the battle). Views that use it `retain()` while on
/// screen and `release()` when they leave; the first retain starts device motion at 30 Hz and the
/// last release stops it. The app pauses it when the scene is not active. Device motion needs no
/// usage string.
///
/// The resting pose is tracked over about four seconds, so however the phone is held the picture
/// settles to centre and only moves with a change of hand.
@MainActor
@Observable
final class TiltSensor {
    static let shared = TiltSensor()

    /// −1…1 on each axis: x from roll (leaning left and right), y from pitch (tipping forward and back).
    private(set) var offset: CGSize = .zero

    @ObservationIgnored private let manager = CMMotionManager()
    @ObservationIgnored private var retainCount = 0
    @ObservationIgnored private var isPaused = false
    /// Low-passed roll and pitch, in radians.
    @ObservationIgnored private var filteredRoll: Double?
    @ObservationIgnored private var filteredPitch: Double?
    /// The slowly tracked resting pose, in radians.
    @ObservationIgnored private var neutralRoll = 0.0
    @ObservationIgnored private var neutralPitch = 0.0

    /// How much of each new sample reaches the filtered tilt (alpha 0.12 at 30 Hz).
    private static let smoothing = 0.12
    /// How fast the resting pose follows the hand: about four seconds at 30 Hz.
    private static let neutralDrift = 1.0 / 120.0
    /// The tilt, in radians, that reads as a full 1.
    private static let range = 0.35
    private static let updatesPerSecond = 30.0

    private init() {}

    /// Whether this device reports motion at all (never on the simulator).
    var isAvailable: Bool {
        manager.isDeviceMotionAvailable
    }

    /// A view that wants the tilt has appeared: 0 → 1 starts device motion.
    func retain() {
        retainCount += 1
        startIfWanted()
    }

    /// A view that wanted the tilt has gone: the last release stops device motion.
    func release() {
        retainCount = max(0, retainCount - 1)
        if retainCount == 0 {
            stop()
        }
    }

    /// Stops updates while paused (the scene is not active, or parallax is off) and restarts them
    /// for whoever is still retaining the sensor when unpaused.
    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused {
            stop()
        } else {
            startIfWanted()
        }
    }

    private func startIfWanted() {
        guard retainCount > 0, !isPaused, !manager.isDeviceMotionActive, manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 1 / Self.updatesPerSecond
        manager.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] motion, _ in
            guard let attitude = motion?.attitude else { return }
            let roll = attitude.roll
            let pitch = attitude.pitch
            MainActor.assumeIsolated {
                self?.ingest(roll: roll, pitch: pitch)
            }
        }
    }

    private func stop() {
        guard manager.isDeviceMotionActive else { return }
        manager.stopDeviceMotionUpdates()
        filteredRoll = nil
        filteredPitch = nil
        offset = .zero
    }

    private func ingest(roll: Double, pitch: Double) {
        guard let currentRoll = filteredRoll, let currentPitch = filteredPitch else {
            // The first sample is the resting pose.
            filteredRoll = roll
            filteredPitch = pitch
            neutralRoll = roll
            neutralPitch = pitch
            return
        }
        let smoothedRoll = currentRoll + (roll - currentRoll) * Self.smoothing
        let smoothedPitch = currentPitch + (pitch - currentPitch) * Self.smoothing
        filteredRoll = smoothedRoll
        filteredPitch = smoothedPitch
        neutralRoll += (roll - neutralRoll) * Self.neutralDrift
        neutralPitch += (pitch - neutralPitch) * Self.neutralDrift
        let next = CGSize(
            width: Self.unit((smoothedRoll - neutralRoll) / Self.range),
            height: Self.unit((smoothedPitch - neutralPitch) / Self.range)
        )
        // Only publish a change the eye could see, so the layers redraw less than 30 times a second at rest.
        if abs(next.width - offset.width) > 0.002 || abs(next.height - offset.height) > 0.002 {
            offset = next
        }
    }

    private static func unit(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, -1), 1))
    }
}

/// The parallax layers' curve. Each sample lands over a quarter second, so 30 samples a second
/// read as one smooth drift. (The spec's 0.25 s ease-out; a `Motion.Curve.parallax` token would
/// move it to MotionTokens.)
private enum Parallax {
    static let settle = Animation.easeOut(duration: 0.25)
}

/// Content that shifts with the device's tilt, `depth` points at a full lean: the farther back a
/// layer sits, the smaller its depth. Retains the `TiltSensor` while on screen and the policy
/// allows parallax (the full tier, no VoiceOver); otherwise it sits still at centre.
struct ParallaxLayer<Content: View>: View {
    let depth: CGFloat
    let content: () -> Content
    @Environment(\.motionPolicy) private var policy
    @State private var isRetaining = false

    init(depth: CGFloat, @ViewBuilder content: @escaping () -> Content) {
        self.depth = depth
        self.content = content
    }

    var body: some View {
        let isOn = policy.allowsParallax
        let tilt = isOn ? TiltSensor.shared.offset : .zero
        content()
            .offset(x: tilt.width * depth, y: tilt.height * depth)
            .animation(Parallax.settle, value: tilt)
            .onAppear { retain(isOn) }
            .onDisappear { retain(false) }
            .onChange(of: isOn) { retain(isOn) }
    }

    private func retain(_ wanted: Bool) {
        guard wanted != isRetaining else { return }
        isRetaining = wanted
        if wanted {
            TiltSensor.shared.retain()
        } else {
            TiltSensor.shared.release()
        }
    }
}
