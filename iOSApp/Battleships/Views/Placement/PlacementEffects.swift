import BattleshipCore
import SwiftUI

// The deploy screen's choreography types and effects (DEP-1, DEP-2, OPN-3): what `FleetPlacementView`
// drives and what `PlacementBoard` draws around its ships.

// MARK: - The cast-off

/// Where the cast-off (DEP-2) has got to. `FleetPlacementView` drives it; `PlacementBoard` draws it.
enum DeployPhase: Equatable, Sendable {
    /// Ships may be moved; nothing is locked.
    case idle
    /// The fleet is confirmed: lock brackets snap onto the ships and the bezel turns green.
    case locking
    /// The ships cast off bow-first while the request is on its way.
    case departing
    /// The request has finished without replacing the screen (an error): the ships sail back.
    case returning

    /// Brackets are on the ships and the bezel is green.
    var isLocked: Bool { self == .locking || self == .departing }
    /// The ships are off their berths.
    var isDeparting: Bool { self == .departing }
}

/// The deploy screen's beats, in seconds: staggers and keyframe timings rather than animation
/// curves (those are `Motion.Curve` tokens), kept here beside the effects that play them, as
/// `RecoilBeat` is kept beside the recoil.
enum DeployBeat {
    /// Between ships dropping anchor on arrival (DEP-1); the carrier first.
    static let arrival: TimeInterval = 0.09
    /// From a ship's arrival to its plunk on the water.
    static let arrivalLanding: TimeInterval = 0.22
    /// From a shuffled ship's take-off to its landing on `Motion.Curve.move`.
    static let flight: TimeInterval = 0.3
    /// Between lock brackets snapping on (DEP-2).
    static let lock: TimeInterval = 0.07
    /// Between ships casting off (DEP-2).
    static let castOff: TimeInterval = 0.04
    /// The slide after a turn, when the model moves a ship along to fit: it follows the turn.
    static let turnSlide: TimeInterval = 0.15
    /// The landing cells' glow after a turn.
    static let turnGlow: TimeInterval = 0.3
    /// The squash on landing: in, then the spring back.
    static let squash: TimeInterval = 0.08
    static let squashRecover: TimeInterval = 0.22
    /// The shudder of a ship refused.
    static let shudder: TimeInterval = 0.28
    /// Each pulse of the red ghost flash and its fall: two pulses in two thirds of a second, under
    /// the three-a-second flash limit.
    static let ghostRise: TimeInterval = 0.12
    static let ghostFall: TimeInterval = 0.21
}

/// Drives the placement screen from outside its gestures: a filmstrip turns a ship, shuffles the
/// fleet or confirms it through one. Optional; the screen works without it.
@MainActor
@Observable
final class PlacementDirector {
    /// Bumped by `rotate(_:)`; `shipIndex` says which ship.
    private(set) var turns = 0
    private(set) var shipIndex = 0
    /// Bumped by `shuffle()`.
    private(set) var shuffles = 0
    /// Bumped by `deploy()`.
    private(set) var deploys = 0

    init() {}

    func rotate(_ index: Int) {
        shipIndex = index
        turns += 1
    }

    func shuffle() {
        shuffles += 1
    }

    func deploy() {
        deploys += 1
    }
}

/// Handed to the deploy closure so its hand-over can wait for the departure: `await handoff.departed()`
/// resolves once the ships have left the board (at once if they already have). The request runs
/// during the cast-off and the next screen arrives when both are done.
@MainActor
final class DeployHandoff {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init() {}

    /// Waits until the ships have cast off.
    func departed() async {
        if isOpen { return }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    /// The ships have gone: everyone waiting may carry on.
    func open() {
        isOpen = true
        let continuations = waiting
        waiting = []
        for continuation in continuations {
            continuation.resume()
        }
    }
}

// MARK: - Around a ship

/// The shadow a lifted ship casts on the water beneath it (the light is top left), drawn under the
/// ships only while one is being dragged.
struct HoverShadow: View {
    /// The ship's cells.
    let rect: CGRect
    let translation: CGSize

    var body: some View {
        let reach = max(rect.width, rect.height) * 0.6
        Ellipse()
            .fill(RadialGradient(colors: [.black.opacity(0.42), .black.opacity(0)], center: .center, startRadius: 0, endRadius: reach))
            .frame(width: rect.width * 1.3, height: rect.height * 1.3)
            .position(x: rect.midX + translation.width + 6, y: rect.midY + translation.height + 10)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The thin white wake a ship trails from its stern as it casts off, laid out horizontally behind
/// the stern of the horizontal art so it turns with the ship. The caller sets its opacity.
struct WakeStreak: View {
    let length: CGFloat
    let beam: CGFloat

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [.white.opacity(0), .white], startPoint: .leading, endPoint: .trailing))
            .frame(width: length, height: max(2, beam * 0.3))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// DEP-2's green lock brackets on one ship: they snap on from 1.9× on `Motion.Curve.slam`, the
/// `index`th `DeployBeat.lock` later than the first, and release the same way. Under the reduced
/// and still tiers they fade in together, and they glow only where flashes are allowed.
struct LockBrackets: View {
    /// The ship's cells.
    let rect: CGRect
    let isLocked: Bool
    let index: Int
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        let snaps = policy.tier == .full
        let delay = snaps ? Double(min(index, Timing.Stagger.maxItems)) * DeployBeat.lock : 0
        CornerBrackets()
            .stroke(Theme.victory, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .frame(width: rect.width + 6, height: rect.height + 6)
            .glow(policy.allowsFlashes ? Theme.victory : .clear, radius: 6)
            .scaleEffect(isLocked || !snaps ? 1 : 1.9)
            .opacity(isLocked ? 1 : 0)
            .animation(Motion.Curve.slam.policy(policy).delay(delay), value: isLocked)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// A green line sweeping round the water's edge as the fleet locks (DEP-2), over the bezel's own
/// crossfade to `Theme.victory`.
struct BezelSweep: View {
    let geometry: BoardGeometry
    let isLocked: Bool
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        let rect = geometry.gridRect
        RoundedRectangle(cornerRadius: min(14, geometry.cell * 0.35), style: .continuous)
            .trim(from: 0, to: isLocked ? 1 : 0)
            .stroke(Theme.victory.opacity(0.9), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: rect.width, height: rect.height)
            .opacity(isLocked ? 1 : 0)
            .animation(Motion.Curve.wipe.policy(policy), value: isLocked)
            .position(x: rect.midX, y: rect.midY)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The landing ghost flashing red twice where a ship could not go (an invalid drop or turn). It
/// plays in every tier: under Reduce Motion it is the whole of the refusal. Never brighter than
/// 0.45, and 0.3 where flashes are off.
struct InvalidGhostFlash: View {
    let ghost: ShipPlacement?
    let geometry: BoardGeometry
    /// Bumped on each refusal.
    let trigger: Int
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        let peak = policy.allowsFlashes ? 0.45 : 0.3
        KeyframeAnimator(initialValue: 0.0, trigger: trigger) { opacity in
            if let ghost {
                let rect = geometry.rect(for: ghost).insetBy(dx: 2, dy: 2)
                RoundedRectangle(cornerRadius: geometry.cell * 0.3, style: .continuous)
                    .fill(Theme.hit.opacity(0.6))
                    .overlay(
                        RoundedRectangle(cornerRadius: geometry.cell * 0.3, style: .continuous)
                            .strokeBorder(Theme.hit, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    )
                    .frame(width: rect.width, height: rect.height)
                    .opacity(opacity)
                    .position(x: rect.midX, y: rect.midY)
            }
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(peak, duration: DeployBeat.ghostRise)
                LinearKeyframe(0, duration: DeployBeat.ghostFall)
                LinearKeyframe(peak, duration: DeployBeat.ghostRise)
                LinearKeyframe(0, duration: DeployBeat.ghostFall)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - On a ship

extension View {
    /// Drops this view onto the water when it appears and whenever `trigger` changes: scale 1.25 → 1
    /// and a fade on `curve`, the `index`th `DeployBeat.arrival` later than the first (DEP-1's
    /// arrival). The reduced tier keeps the stagger on `Motion.Curve.reduced`; the still tier and
    /// collapsed sequences fade everything in together.
    func dropsAnchor(index: Int, trigger: some Equatable, curve: Animation = Motion.Curve.settle) -> some View {
        modifier(DropsAnchor(index: index, trigger: trigger, curve: curve))
    }

    /// The squash of a ship landing on the water (x 1.04 / y 0.96 for `DeployBeat.squash`, then a
    /// springy recovery), replayed whenever `trigger` changes. Nothing in the still tier.
    func dropSquash(on trigger: Int) -> some View {
        modifier(DropSquash(trigger: trigger))
    }

    /// The shudder of a ship refused: ±5 pt and ±2°, decaying over `DeployBeat.shudder`, replayed
    /// whenever `trigger` changes. Nothing below the full tier (the red ghost flash carries the news).
    func shipShudder(on trigger: Int) -> some View {
        modifier(ShipShudder(trigger: trigger))
    }
}

private struct DropsAnchor<Trigger: Equatable>: ViewModifier {
    let index: Int
    let trigger: Trigger
    let curve: Animation
    @Environment(\.motionPolicy) private var policy
    @State private var hasLanded = false

    func body(content: Content) -> some View {
        let scales = policy.tier != .still
        content
            .scaleEffect(hasLanded || !scales ? 1 : 1.25)
            .opacity(hasLanded ? 1 : 0)
            .onAppear { land() }
            .onChange(of: trigger) { replay() }
    }

    private func land() {
        let staggers = !policy.collapsesSequences && !policy.holdsStill
        let delay = staggers ? Double(min(max(0, index), Timing.Stagger.maxItems)) * DeployBeat.arrival : 0
        withAnimation(curve.policy(policy).delay(delay)) {
            hasLanded = true
        }
    }

    /// Lifts without animating, then lands on the next turn of the run loop so the drop plays again.
    private func replay() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            hasLanded = false
        }
        Task { @MainActor in
            land()
        }
    }
}

private struct SquashPose {
    var x: CGFloat = 1
    var y: CGFloat = 1
}

private struct DropSquash: ViewModifier {
    let trigger: Int
    @Environment(\.motionPolicy) private var policy

    func body(content: Content) -> some View {
        let squashes = policy.tier != .still
        KeyframeAnimator(initialValue: SquashPose(), trigger: trigger) { pose in
            content.scaleEffect(x: pose.x, y: pose.y)
        } keyframes: { _ in
            KeyframeTrack(\.x) {
                LinearKeyframe(squashes ? 1.04 : 1, duration: DeployBeat.squash)
                SpringKeyframe(1, duration: DeployBeat.squashRecover, spring: .bouncy)
            }
            KeyframeTrack(\.y) {
                LinearKeyframe(squashes ? 0.96 : 1, duration: DeployBeat.squash)
                SpringKeyframe(1, duration: DeployBeat.squashRecover, spring: .bouncy)
            }
        }
    }
}

private struct ShudderPose {
    var dx: CGFloat = 0
    var roll: Double = 0
}

private struct ShipShudder: ViewModifier {
    let trigger: Int
    @Environment(\.motionPolicy) private var policy

    func body(content: Content) -> some View {
        let amplitude: CGFloat = policy.tier == .full ? 5 : 0
        let roll: Double = policy.tier == .full ? 2 : 0
        KeyframeAnimator(initialValue: ShudderPose(), trigger: trigger) { pose in
            content
                .offset(x: pose.dx)
                .rotationEffect(.degrees(pose.roll))
        } keyframes: { _ in
            KeyframeTrack(\.dx) {
                LinearKeyframe(amplitude, duration: DeployBeat.shudder * 0.15)
                LinearKeyframe(-amplitude * 0.8, duration: DeployBeat.shudder * 0.2)
                LinearKeyframe(amplitude * 0.5, duration: DeployBeat.shudder * 0.2)
                LinearKeyframe(-amplitude * 0.25, duration: DeployBeat.shudder * 0.2)
                LinearKeyframe(0, duration: DeployBeat.shudder * 0.25)
            }
            KeyframeTrack(\.roll) {
                LinearKeyframe(roll, duration: DeployBeat.shudder * 0.15)
                LinearKeyframe(-roll * 0.8, duration: DeployBeat.shudder * 0.2)
                LinearKeyframe(roll * 0.5, duration: DeployBeat.shudder * 0.2)
                LinearKeyframe(-roll * 0.25, duration: DeployBeat.shudder * 0.2)
                LinearKeyframe(0, duration: DeployBeat.shudder * 0.25)
            }
        }
    }
}

// MARK: - Plunks

/// A ship's plunk on the water: `Emitters.plunk`'s droplets and rings off its hull where it landed
/// (DEP-1), built once and drawn by `PlacementEffectsLayer`. `x`, `y` and `start` are as for `WaterImpact`.
struct Plunk: Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat
    var start: TimeInterval
    /// Seconds until its last particle has gone.
    var duration: TimeInterval
    var particles: [Particle]

    /// A plunk from a ship landing in `rect` (the board's coordinates) on cells of `cell` points.
    init(rect: CGRect, cell: CGFloat, start: TimeInterval) {
        x = rect.midX
        y = rect.midY
        self.start = start
        let unit = Double(max(cell, 1))
        let width = Double(rect.width) / unit
        let height = Double(rect.height) / unit
        particles = Emitters.plunk(rect: SIMD4(-width / 2, -height / 2, width, height), seed: start.bitPattern)
        duration = particles.map { $0.delay + $0.life }.max() ?? 0
    }
}

/// One Canvas for every plunk on the placement board, drawn by `ParticleRenderer`, ticking only
/// while a plunk is live and only in the full tier (the reduced tier keeps the water's rings and
/// drops the droplets).
struct PlacementEffectsLayer: View {
    let plunks: [Plunk]
    let cell: CGFloat
    @Environment(\.motionPolicy) private var policy
    /// Set while a plunk is young, so the clock ticks for it and sleeps again after it.
    @State private var hasLivePlunk = false

    var body: some View {
        let draws = policy.tier == .full
        let flashes = policy.allowsFlashes
        let budget = policy.particleBudget
        LoopClock(loop: .effects, isLive: draws && hasLivePlunk) { seconds in
            Canvas { context, _ in
                guard let seconds else { return }
                for plunk in plunks {
                    ParticleRenderer.draw(
                        plunk.particles,
                        elapsed: seconds - plunk.start,
                        unit: cell,
                        at: CGPoint(x: plunk.x, y: plunk.y),
                        flashes: flashes,
                        budget: budget,
                        in: &context
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: plunks.last?.start) {
            guard let newest = plunks.last else {
                hasLivePlunk = false
                return
            }
            let remaining = newest.start + newest.duration - Date().timeIntervalSinceReferenceDate
            guard remaining > 0 else {
                hasLivePlunk = false
                return
            }
            hasLivePlunk = true
            try? await Task.sleep(for: .seconds(remaining + 0.05))
            guard !Task.isCancelled else { return }
            hasLivePlunk = false
        }
    }
}

// MARK: - The "vs" chip

/// "vs nemo": who the fleet will face, above the deploy board (OPN-3's rematch chip; a challenge's too).
struct DeployOpponentChip: View {
    let name: String

    var body: some View {
        HStack(spacing: 8) {
            OpponentAvatar(name: name, isComputer: isComputer, size: 24)
            Text("vs")
                .scaledFont(12, weight: .heavy, design: .rounded, relativeTo: .caption)
                .foregroundStyle(Theme.secondaryText)
            Text(name)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.leading)
        }
        .padding(.vertical, 6)
        .padding(.leading, 6)
        .padding(.trailing, 14)
        .background(Capsule().fill(.white.opacity(0.1)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Versus \(name)")
    }

    /// The computer is named by its level ("Computer · Admiral"); anyone else is a captain.
    private var isComputer: Bool {
        name.localizedStandardContains("Computer")
    }
}
