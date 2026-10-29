import SwiftUI

/// The finale's beats that `Timing` does not carry yet (the spec marks them `// new`): one named
/// set here, to move into `Timing` when the foundation owner adds them. No other duration literal
/// lives in the ceremony code.
enum FinaleBeat {
    /// The first rocket, from the start of the victory sheet.
    static let fireworksStart: TimeInterval = 0.3
    /// The dense volley is over: six rockets, 0.5–0.6 s apart.
    static let fireworksDense: TimeInterval = 3.2
    /// The last rocket has gone up; the sky is quiet after it.
    static let fireworksEnd: TimeInterval = 8
    /// Between the sparse rockets after the volley.
    static let fireworksSparseGap: TimeInterval = 2.5
    /// The lightning's rise and fall.
    static let strikeIn: TimeInterval = 0.08
    static let strikeOut: TimeInterval = 0.5
    /// The rain: when it starts, how long it takes to reach full density, when it thins and when it stops.
    static let rainStart: TimeInterval = 0.4
    static let rainRamp: TimeInterval = 1.5
    static let rainThin: TimeInterval = 6
    static let rainStop: TimeInterval = 12
    /// The stats roll from this beat of the victory sheet, over `statsRoll`; the rating over `ratingRoll`.
    static let statsStart: TimeInterval = 1.6
    static let statsRoll: TimeInterval = 0.8
    static let ratingRoll: TimeInterval = 1.4
}

// MARK: - Fireworks

/// The victory's sky: rockets climbing from the bottom corners and the centre on bright streaks
/// and bursting at their apex into sparks (peony, chrysanthemum or willow), gold through white to
/// ember, drawn additively. One `TimelineView` and one Canvas at the policy's effects rate; the
/// particle list is generated once from `seed` and read per frame, never mutated.
///
/// The schedule is the spec's: six rockets 0.5–0.6 s apart from `FinaleBeat.fireworksStart` (so
/// never more than two bursts in any second), then one every `fireworksSparseGap` until
/// `fireworksEnd`, then nothing: the timeline pauses once the last spark has died. The reduced tier
/// flies three rockets at 30 frames a second within its particle budget; the still tier flies none
/// (the caller leaves the view out under `policy.allowsParticles`). Without flashes there are no
/// white cores and the sparks burn at 60 %.
struct FireworksView: View {
    let seed: UInt64
    /// After the dense volley only the occasional rocket flies. Flipping it early (a skipped
    /// ceremony) drops the dense rockets still to launch, so the sky calms with the card.
    var isSparse = false
    /// Called once per burst with its pan (−1 left … 1 right), for the `.firework` pop.
    var onBurst: (@MainActor (Double) -> Void)? = nil

    @State private var start = Date()
    @State private var rockets: [FireworkSky.Rocket] = []
    @State private var sparseSince: TimeInterval?
    @State private var burstsHeard = 0
    @State private var isOver = false
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        let isLive = policy.allowsParticles && !policy.holdsStill && !isOver
        TimelineView(.animation(minimumInterval: policy.effectsInterval, paused: !isLive)) { timeline in
            let elapsed = timeline.date.timeIntervalSince(start)
            let frame = FireworkSky.Frame(
                elapsed: elapsed,
                rockets: rockets,
                cutoff: sparseSince ?? .infinity,
                flashes: policy.allowsFlashes,
                budget: policy.particleBudget
            )
            Canvas(rendersAsynchronously: true) { context, size in
                FireworkSky.draw(frame, size: size, in: &context)
            }
            .onChange(of: frame.burstCount, initial: true) {
                heard(frame)
            }
        }
        .motionBudgeted(isLive: isLive)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onChange(of: policy.tier, initial: true) {
            let isFull = policy.tier == .full
            rockets = FireworkSky.schedule(seed: seed, denseRockets: isFull ? 6 : 3, sparseRockets: isFull ? 2 : 0)
        }
        .onChange(of: isSparse, initial: true) {
            if isSparse, sparseSince == nil {
                sparseSince = Date().timeIntervalSince(start)
            }
        }
        .task {
            try? await Task.sleep(for: .seconds(FinaleBeat.fireworksEnd + FireworkSky.flight + FireworkSky.longestLife))
            isOver = true
        }
    }

    /// Pops for the bursts that have happened since the last frame.
    private func heard(_ frame: FireworkSky.Frame) {
        let pans = frame.burstPans()
        guard pans.count > burstsHeard else { return }
        for pan in pans.dropFirst(burstsHeard) {
            onBurst?(pan)
        }
        burstsHeard = pans.count
    }
}

/// The maths and drawing of `FireworksView`: value types and `nonisolated` functions, so the Canvas
/// can render asynchronously from a frame it was handed. Positions are in unit coordinates, 0…1 of
/// the screen's width and height; spark speeds are in screen heights a second.
enum FireworkSky {
    /// Seconds a rocket climbs before it bursts.
    static let flight: TimeInterval = 0.85
    /// The longest a spark lives (a willow's).
    static let longestLife: TimeInterval = 2.2
    /// The rocket's launch lanes: the bottom corners and the centre.
    static let lanes: [CGFloat] = [0.1, 0.5, 0.9]

    enum Burst: Sendable, CaseIterable {
        /// A round ball of dots.
        case peony
        /// Dots with short trails that reach further.
        case chrysanthemum
        /// Long trails that droop under gravity and linger.
        case willow
    }

    struct Spark: Sendable {
        /// Direction of travel, in radians.
        let angle: Double
        /// At the burst, in screen heights a second.
        let speed: Double
        let life: TimeInterval
        /// In points.
        let radius: CGFloat
        /// 0…1 along the burst's colour ramp.
        let tint: Double
        /// Per second; the spark's speed decays by it.
        let drag: Double
        /// Downward pull, in screen heights a second².
        let gravity: Double
        /// Seconds of trail drawn behind the spark; 0 for a dot.
        let trail: TimeInterval
    }

    struct Rocket: Sendable {
        /// Seconds after the sky's start.
        let launch: TimeInterval
        /// Unit coordinates: from just under the bottom edge…
        let origin: CGPoint
        /// …to where it bursts, in the upper sky.
        let apex: CGPoint
        let burst: Burst
        /// One of the occasional rockets after the dense volley.
        let isSparse: Bool
        let sparks: [Spark]

        var burstTime: TimeInterval { launch + FireworkSky.flight }
        /// −1 left … 1 right, from where the burst blooms.
        var pan: Double { Double(apex.x) * 2 - 1 }
        var endTime: TimeInterval { burstTime + (sparks.map(\.life).max() ?? 0) }
    }

    /// Everything one frame draws from.
    struct Frame: Sendable {
        let elapsed: TimeInterval
        let rockets: [Rocket]
        /// Dense rockets launching at or after this never fly (the sky was told to calm).
        let cutoff: TimeInterval
        let flashes: Bool
        let budget: Int

        func flies(_ rocket: Rocket) -> Bool {
            rocket.isSparse || rocket.launch < cutoff
        }

        /// The rockets that have burst by now, in launch order.
        var burstCount: Int {
            rockets.filter { flies($0) && $0.burstTime <= elapsed }.count
        }

        func burstPans() -> [Double] {
            rockets.filter { flies($0) && $0.burstTime <= elapsed }.map(\.pan)
        }
    }

    // MARK: Generation

    /// The sky's rockets, in launch order, the same for a `seed` every time.
    nonisolated static func schedule(seed: UInt64, denseRockets: Int, sparseRockets: Int) -> [Rocket] {
        var generator = SplitMix64(seed: seed)
        var rockets: [Rocket] = []
        var launch = FinaleBeat.fireworksStart
        for index in 0..<max(0, denseRockets) {
            rockets.append(makeRocket(launch: launch, lane: index % lanes.count, index: index, isSparse: false, using: &generator))
            launch += Double.random(in: 0.5...0.6, using: &generator)
        }
        for index in 0..<max(0, sparseRockets) {
            let sparseLaunch = FinaleBeat.fireworksDense + 0.5 + Double(index) * FinaleBeat.fireworksSparseGap
            guard sparseLaunch <= FinaleBeat.fireworksEnd else { break }
            let lane = Int.random(in: 0..<lanes.count, using: &generator)
            rockets.append(makeRocket(launch: sparseLaunch, lane: lane, index: denseRockets + index, isSparse: true, using: &generator))
        }
        return rockets
    }

    private nonisolated static func makeRocket(
        launch: TimeInterval,
        lane: Int,
        index: Int,
        isSparse: Bool,
        using generator: inout SplitMix64
    ) -> Rocket {
        let originX = lanes[lane]
        let drift = (0.5 - originX) * 0.35 + CGFloat(Double.random(in: -0.06...0.06, using: &generator))
        let apex = CGPoint(x: originX + drift, y: CGFloat(Double.random(in: 0.16...0.36, using: &generator)))
        let burst = Burst.allCases[index % Burst.allCases.count]
        let count = Int.random(in: 60...90, using: &generator)
        var sparks: [Spark] = []
        sparks.reserveCapacity(count)
        for _ in 0..<count {
            let angle = Double.random(in: 0..<(2 * Double.pi), using: &generator)
            let tint = Double.random(in: 0...1, using: &generator)
            switch burst {
            case .peony:
                sparks.append(Spark(
                    angle: angle,
                    speed: Double.random(in: 0.16...0.22, using: &generator),
                    life: Double.random(in: 0.9...1.3, using: &generator),
                    radius: CGFloat(Double.random(in: 1.6...2.8, using: &generator)),
                    tint: tint,
                    drag: 2.6,
                    gravity: 0.05,
                    trail: 0
                ))
            case .chrysanthemum:
                sparks.append(Spark(
                    angle: angle,
                    speed: Double.random(in: 0.2...0.3, using: &generator),
                    life: Double.random(in: 1.0...1.5, using: &generator),
                    radius: CGFloat(Double.random(in: 1.3...2.2, using: &generator)),
                    tint: tint,
                    drag: 2.2,
                    gravity: 0.06,
                    trail: 0.07
                ))
            case .willow:
                sparks.append(Spark(
                    angle: angle,
                    speed: Double.random(in: 0.12...0.2, using: &generator),
                    life: Double.random(in: 1.6...longestLife, using: &generator),
                    radius: CGFloat(Double.random(in: 1.2...2.0, using: &generator)),
                    tint: tint,
                    drag: 1.4,
                    gravity: 0.12,
                    trail: 0.12
                ))
            }
        }
        return Rocket(launch: launch, origin: CGPoint(x: originX, y: 1.04), apex: apex, burst: burst, isSparse: isSparse, sparks: sparks)
    }

    // MARK: Evaluation

    /// Where a rocket is `progress` (0…1) of the way up, in unit coordinates: straight across, easing
    /// out as it climbs, with a slight curl.
    nonisolated static func climb(_ rocket: Rocket, progress: Double) -> CGPoint {
        let p = min(max(progress, 0), 1)
        let eased = 1 - (1 - p) * (1 - p)
        let curl = sin(p * Double.pi) * 0.025 * (rocket.apex.x < 0.5 ? 1 : -1)
        return CGPoint(
            x: rocket.origin.x + (rocket.apex.x - rocket.origin.x) * CGFloat(p) + CGFloat(curl),
            y: rocket.origin.y + (rocket.apex.y - rocket.origin.y) * CGFloat(eased)
        )
    }

    /// Where a spark is `age` seconds after its burst, in unit coordinates from `apex`.
    nonisolated static func position(of spark: Spark, age: TimeInterval, apex: CGPoint) -> CGPoint {
        let a = max(0, age)
        let travelled = spark.drag > 0 ? (1 - exp(-spark.drag * a)) / spark.drag : a
        let distance = spark.speed * travelled
        return CGPoint(
            x: apex.x + CGFloat(cos(spark.angle) * distance),
            y: apex.y + CGFloat(sin(spark.angle) * distance + 0.5 * spark.gravity * a * a)
        )
    }

    /// The spark's colour `t` (0…1) of the way through its life: gold, through white when flashes are
    /// allowed (ember when not), to flame or red by its tint.
    nonisolated static func color(at t: Double, tint: Double, flashes: Bool) -> Color {
        let gold = (1.0, 0.82, 0.3)
        let hot = flashes ? (1.0, 1.0, 0.96) : (1.0, 0.87, 0.45)
        let end = tint < 0.5 ? (1.0, 0.68, 0.22) : (1.0, 0.33, 0.24)
        let x = min(max(t, 0), 1)
        let from: (Double, Double, Double)
        let to: (Double, Double, Double)
        let mix: Double
        if x < 0.3 {
            from = gold
            to = hot
            mix = x / 0.3
        } else if x < 0.6 {
            from = hot
            to = gold
            mix = (x - 0.3) / 0.3
        } else {
            from = gold
            to = end
            mix = (x - 0.6) / 0.4
        }
        return Color(
            red: from.0 + (to.0 - from.0) * mix,
            green: from.1 + (to.1 - from.1) * mix,
            blue: from.2 + (to.2 - from.2) * mix
        )
    }

    // MARK: Drawing

    nonisolated static func draw(_ frame: Frame, size: CGSize, in context: inout GraphicsContext) {
        guard size.width > 0, size.height > 0 else { return }
        var budget = frame.budget
        var sparks = context
        sparks.blendMode = .plusLighter
        for rocket in frame.rockets where frame.flies(rocket) {
            let since = frame.elapsed - rocket.launch
            guard since >= 0, frame.elapsed < rocket.endTime else { continue }
            if since < flight {
                drawClimb(rocket, progress: since / flight, size: size, flashes: frame.flashes, in: &sparks)
                continue
            }
            let age = frame.elapsed - rocket.burstTime
            let apex = CGPoint(x: rocket.apex.x * size.width, y: rocket.apex.y * size.height)
            if frame.flashes, age < 0.12 {
                // The white core, small and brief: the one flash a burst makes.
                let radius = 8 + 60 * age
                sparks.fill(
                    Path(ellipseIn: CGRect(x: apex.x - radius, y: apex.y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(.white.opacity(0.9 * (1 - age / 0.12)))
                )
            }
            for spark in rocket.sparks where age < spark.life {
                guard budget > 0 else { return }
                budget -= 1
                let t = age / spark.life
                let fade = pow(1 - t, 1.3) * (frame.flashes ? 1 : 0.6)
                let paint = color(at: t, tint: spark.tint, flashes: frame.flashes).opacity(fade)
                let head = point(position(of: spark, age: age, apex: rocket.apex), size: size)
                if spark.trail > 0 {
                    let tail = point(position(of: spark, age: age - spark.trail, apex: rocket.apex), size: size)
                    var streak = Path()
                    streak.move(to: tail)
                    streak.addLine(to: head)
                    sparks.stroke(streak, with: .color(paint), style: StrokeStyle(lineWidth: spark.radius * 1.4, lineCap: .round))
                } else {
                    let radius = spark.radius * CGFloat(1 - 0.4 * t)
                    sparks.fill(
                        Path(ellipseIn: CGRect(x: head.x - radius, y: head.y - radius, width: radius * 2, height: radius * 2)),
                        with: .color(paint)
                    )
                }
            }
        }
    }

    /// The rocket on its way up: a short bright streak with a few sparkles behind it.
    private nonisolated static func drawClimb(_ rocket: Rocket, progress: Double, size: CGSize, flashes: Bool, in context: inout GraphicsContext) {
        let head = point(climb(rocket, progress: progress), size: size)
        let tail = point(climb(rocket, progress: progress - 0.1), size: size)
        var streak = Path()
        streak.move(to: tail)
        streak.addLine(to: head)
        context.stroke(
            streak,
            with: .linearGradient(
                Gradient(colors: [Theme.gold.opacity(0), Theme.gold.opacity(0.9)]),
                startPoint: tail,
                endPoint: head
            ),
            style: StrokeStyle(lineWidth: 2, lineCap: .round)
        )
        let headColor: Color = flashes ? .white : Theme.ember
        context.fill(
            Path(ellipseIn: CGRect(x: head.x - 2.5, y: head.y - 2.5, width: 5, height: 5)),
            with: .color(headColor.opacity(0.95))
        )
        for index in 1...3 {
            let behind = climb(rocket, progress: progress - 0.035 * Double(index))
            let wobble = CGFloat(sin(progress * 40 + Double(index) * 2.1)) * 3
            let sparkle = CGPoint(x: behind.x * size.width + wobble, y: behind.y * size.height)
            let radius: CGFloat = 1.2
            context.fill(
                Path(ellipseIn: CGRect(x: sparkle.x - radius, y: sparkle.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(Theme.ember.opacity(0.6 * (1 - Double(index) / 4)))
            )
        }
    }

    private nonisolated static func point(_ unit: CGPoint, size: CGSize) -> CGPoint {
        CGPoint(x: unit.x * size.width, y: unit.y * size.height)
    }
}

// MARK: - The rating tile and the chips

/// The RATING tile on the victory card of an online game: the rating rolls from the old value to
/// the new over `FinaleBeat.ratingRoll` beside a "+18" that floats up (`DeltaChip`), with a
/// PERSONAL BEST ribbon when it is a new best. One VoiceOver element: "Rating, 1,184, up 18,
/// personal best". Until the delta has arrived the tile shows the old rating; it rolls when the
/// new one comes.
struct RatingStat: View {
    let from: Int
    let to: Int
    let delta: Int?
    let isBest: Bool
    var roll: CountingStat.Roll = .rolling
    @Environment(\.motionPolicy) private var policy
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                number
                if let delta, roll != .waiting {
                    deltaBadge(delta)
                        .overlay {
                            // The copy that floats up and fades as the number starts to roll.
                            DeltaChip(delta: delta, trigger: AnyHashable(delta))
                        }
                }
            }
            Text("Rating")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            if isBest, roll != .waiting {
                PersonalBestRibbon()
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rating")
        .accessibilityValue(spokenValue)
    }

    @ViewBuilder
    private var number: some View {
        switch roll {
        case .rolling where !policy.collapsesSequences:
            OneShotClock(duration: FinaleBeat.ratingRoll) { elapsed in
                ratingText(value(at: elapsed))
            }
            .id(to)
        case .waiting:
            ratingText(from)
        default:
            ratingText(to)
        }
    }

    private func ratingText(_ value: Int) -> some View {
        Text(value.formatted())
            .font(.title2.weight(.bold).monospacedDigit())
            .foregroundStyle(Theme.goldLeaf)
    }

    private func value(at elapsed: TimeInterval) -> Int {
        let progress = Easing.easeOut(elapsed / FinaleBeat.ratingRoll)
        return from + Int((Double(to - from) * progress).rounded())
    }

    /// The "+18" that stays beside the rating, in the chip's own style.
    private func deltaBadge(_ delta: Int) -> some View {
        Text(delta >= 0 ? "+\(delta)" : "−\(-delta)")
            .scaledFont(13, weight: .heavy, design: .rounded, relativeTo: .footnote)
            .monospacedDigit()
            .foregroundStyle(delta >= 0 ? Theme.victory : Theme.hit)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background((delta >= 0 ? Theme.victory : Theme.hit).opacity(0.16), in: Capsule())
    }

    private var spokenValue: String {
        var parts = [to.formatted()]
        if let delta {
            parts.append(delta >= 0 ? "up \(delta)" : "down \(-delta)")
        }
        if isBest {
            parts.append("personal best")
        }
        return parts.joined(separator: ", ")
    }
}

/// A gold ribbon under a new best rating.
struct PersonalBestRibbon: View {
    var body: some View {
        Label("PERSONAL BEST", systemImage: "star.fill")
            .scaledFont(11, weight: .heavy, design: .rounded, relativeTo: .caption2)
            .tracking(1.2)
            .foregroundStyle(Theme.gold)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Theme.gold.opacity(0.16), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.gold.opacity(0.5), lineWidth: 1))
            .accessibilityLabel("Personal best")
    }
}

/// The solo winning run on the victory card: "WINNING RUN ×3" in a gold capsule, a plain line of
/// text at accessibility sizes. Never called a streak.
struct WinningRunChip: View {
    let count: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                Text("Winning run: \(count) battles")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.gold)
                    .multilineTextAlignment(.center)
            } else {
                Text("WINNING RUN ×\(count)")
                    .scaledFont(12, weight: .heavy, design: .rounded, relativeTo: .caption)
                    .tracking(1.4)
                    .monospacedDigit()
                    .foregroundStyle(Theme.gold)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Theme.gold.opacity(0.16), in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.gold.opacity(0.5), lineWidth: 1))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Winning run, \(count) battles")
    }
}
