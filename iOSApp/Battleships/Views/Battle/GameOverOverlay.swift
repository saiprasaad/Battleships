import BattleshipCore
import SwiftUI

/// Everything the end-of-battle card has to say: who won and how, the shooting record, the rating
/// news for an online game, the solo winning run, and the enemy's waters at the end for the
/// shareable picture. A plain value, so the controller can publish it and the overlay can hold it.
struct GameOverSummary: Equatable, Sendable {
    var didWin: Bool
    var reason: Outcome.Reason?
    var opponentName: String
    var stats: ShotStats
    /// The player's rating before an online game; nil for a game against the computer (no RATING tile).
    var ratingBefore: Int?
    /// How the rating moved, once the server has said; nil until it has (the tile shows the old rating meanwhile).
    var ratingDelta: Int?
    /// The new rating is the player's best so far.
    var isPersonalBest: Bool
    /// The run of solo wins this game extends; shown as a WINNING RUN chip from two.
    var soloStreak: Int?
    /// The enemy's waters as they ended, with the revealed fleet, for `ResultCard`.
    var finalBoard: BattlePerspective?

    init(
        didWin: Bool,
        reason: Outcome.Reason? = nil,
        opponentName: String,
        stats: ShotStats,
        ratingBefore: Int? = nil,
        ratingDelta: Int? = nil,
        isPersonalBest: Bool = false,
        soloStreak: Int? = nil,
        finalBoard: BattlePerspective? = nil
    ) {
        self.didWin = didWin
        self.reason = reason
        self.opponentName = opponentName
        self.stats = stats
        self.ratingBefore = ratingBefore
        self.ratingDelta = ratingDelta
        self.isPersonalBest = isPersonalBest
        self.soloStreak = soloStreak
        self.finalBoard = finalBoard
    }

    /// The rating after the game, once the delta has arrived; the old one until then.
    var ratingAfter: Int? {
        ratingBefore.map { $0 + (ratingDelta ?? 0) }
    }

    /// Online games show the RATING tile.
    var showsRating: Bool {
        ratingBefore != nil
    }

    /// The solo winning run worth a chip: two wins or more, on a win.
    var winningRun: Int? {
        guard didWin, let soloStreak, soloStreak >= 2 else { return nil }
        return soloStreak
    }

    /// The battle ended with a fleet on the bottom (the fanfare or lament already played at the
    /// SUNK stamp); a resignation or timeout plays it on the card instead.
    var endedByFleetDestruction: Bool {
        reason == nil || reason == .fleetDestroyed
    }
}

/// How the card arrives: the ceremony plays once, when the battle ends; the Summary button and any
/// later look show the recap, which is the landed card with nothing moving and no sound.
enum GameOverPresentation: Equatable, Sendable {
    case ceremony
    case recap
}

/// The end-of-battle card. A win: night rises, a sunburst comes up, fireworks, the trophy and
/// VICTORY, the stats roll and Rematch arms. A loss: night falls, rain, one strike of lightning, and
/// the DEFEAT card surfaces through a draining veil with a ship going down in it. Rematch, View the
/// Board and Share are live from the card's first frame; tapping outside the card skips the
/// ceremony, and closes the card once it has landed.
struct GameOverOverlay: View {
    let summary: GameOverSummary
    let presentation: GameOverPresentation
    /// Fireworks may fly (the old call sites' flag; the motion policy has the final say).
    let celebrates: Bool
    let onRematch: @MainActor () -> Void
    let onClose: @MainActor () -> Void

    @State private var isSkipped = false
    @State private var hasLanded = false
    /// Bumped when the lightning cue fires; `LightningFlash` plays on the change.
    @State private var strikes = 0
    @AccessibilityFocusState private var isTitleFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.motionPolicy) private var policy
    @Environment(AppModel.self) private var app: AppModel?

    init(
        summary: GameOverSummary,
        presentation: GameOverPresentation = .ceremony,
        onRematch: @escaping @MainActor () -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.summary = summary
        self.presentation = presentation
        celebrates = true
        self.onRematch = onRematch
        self.onClose = onClose
    }

    /// The original call: builds a summary without rating news and plays the ceremony.
    init(
        didWin: Bool,
        reason: Outcome.Reason?,
        opponentName: String,
        stats: ShotStats,
        celebrates: Bool,
        onRematch: @escaping @MainActor () -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        summary = GameOverSummary(didWin: didWin, reason: reason, opponentName: opponentName, stats: stats)
        presentation = .ceremony
        self.celebrates = celebrates
        self.onRematch = onRematch
        self.onClose = onClose
    }

    var body: some View {
        Group {
            if presentation == .ceremony {
                CuePlayer(
                    sheet: sheet,
                    trigger: summary.didWin,
                    isSkipped: isSkipped,
                    onCue: { cue in handle(cue) },
                    onFinished: { hasLanded = true }
                ) { frame in
                    stage(frame)
                }
            } else {
                stage(sheet.frame(at: sheet.total, collapsed: true))
            }
        }
        .onAppear {
            app?.setAmbientScene(.gameOver(didWin: summary.didWin))
        }
        .task {
            // The card is modal, so VoiceOver starts on its title once it has faded in.
            try? await Task.sleep(for: .milliseconds(600))
            isTitleFocused = true
        }
    }

    // MARK: The sheets

    /// The victory beats (FIN-2): 3.5 s, then only the occasional rocket in `FireworksView`.
    private static let victorySheet = CueSheet([
        Cue(name: "scrim", start: 0, duration: 0.5),
        Cue(name: "sunburst", start: 0, duration: 0.6),
        Cue(name: "fanfare", start: 0),
        Cue(name: "card", start: 0.3),
        Cue(name: "fireworks", start: FinaleBeat.fireworksStart, duration: FinaleBeat.fireworksDense - FinaleBeat.fireworksStart),
        Cue(name: "trophy", start: 0.8),
        Cue(name: "bloom", start: 0.8, duration: 0.7),
        Cue(name: "title", start: 0.8, duration: 0.6),
        Cue(name: "sweep", start: 1.1, duration: 0.5),
        Cue(name: "stats", start: FinaleBeat.statsStart, duration: 0.3),
        Cue(name: "arm", start: 2.2),
    ], total: 3.5)

    /// The defeat beats (FIN-3): the card by 2 s; the rain's own envelope runs on to `rainStop`.
    private static let defeatSheet = CueSheet([
        Cue(name: "night", start: 0, duration: 1.6),
        Cue(name: "lament", start: 0),
        Cue(name: "rain", start: FinaleBeat.rainStart),
        Cue(name: "strike", start: 1.2),
        Cue(name: "card", start: 1.4, duration: 0.6),
        Cue(name: "thunder", start: 1.6),
        Cue(name: "title", start: 1.7, duration: 0.55),
        Cue(name: "stats", start: 2.0, duration: 0.3),
        Cue(name: "arm", start: 2.5),
    ], total: 2.6)

    private var sheet: CueSheet {
        summary.didWin ? Self.victorySheet : Self.defeatSheet
    }

    /// Sounds and haptics on their beats. Nothing plays in the recap (it never fires cues) and
    /// nothing plays for a skipped sequence's leftovers.
    private func handle(_ cue: String) {
        switch cue {
        case "fanfare":
            if !summary.endedByFleetDestruction {
                app?.feedback.play(.victory)
            }
        case "lament":
            if !summary.endedByFleetDestruction {
                app?.feedback.play(.defeat)
            }
        case "strike":
            if policy.allowsFlashes, !policy.collapsesSequences, !isSkipped {
                strikes += 1
            }
        case "thunder":
            if !policy.collapsesSequences, !isSkipped {
                app?.feedback.play(.thunder)
            }
        default:
            break
        }
    }

    /// The ceremony has landed (or there was none): a tap outside the card closes it; before that
    /// the tap skips to the end.
    private var isFinished: Bool {
        presentation == .recap || hasLanded
    }

    private func tapOutside() {
        if isFinished {
            onClose()
        } else {
            isSkipped = true
        }
    }

    // MARK: The stage

    private func stage(_ frame: CueSheet.Frame) -> some View {
        let isLive = presentation == .ceremony
        return ZStack {
            if summary.didWin {
                victoryBackdrop(frame, isLive: isLive)
            } else {
                defeatBackdrop(frame, isLive: isLive)
            }

            CenteredScrollView {
                card(frame, isLive: isLive)
            } onTapOutside: {
                tapOutside()
            }
        }
    }

    private func victoryBackdrop(_ frame: CueSheet.Frame, isLive: Bool) -> some View {
        ZStack {
            RisingScrim(progress: frame.progress("scrim"))
                // An overlay, so the sunburst's size doesn't stretch the screen it covers.
                .overlay {
                    Sunburst(isLive: isLive)
                        .frame(width: 720, height: 720)
                        .offset(y: -170)
                        .opacity(frame.progress("sunburst"))
                }
            if isLive, celebrates, policy.allowsParticles {
                FireworksView(seed: fireworksSeed, isSparse: frame.hasEnded("fireworks")) { pan in
                    app?.feedback.play(.firework, variation: FeedbackVariation(pan: pan))
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { tapOutside() }
        .accessibilityHidden(true)
    }

    private func defeatBackdrop(_ frame: CueSheet.Frame, isLive: Bool) -> some View {
        let night = frame.progress("night", curve: Easing.easeInOut)
        return ZStack {
            Nightfall(progress: night)
            RadialGradient(colors: [Theme.hit.opacity(0), Theme.hit.opacity(0.3)], center: .center, startRadius: 160, endRadius: 560)
                .ignoresSafeArea()
            // Its own envelope waits for the "rain" beat; the recap shows it still.
            RainView(density: 1, wind: 0.3, isLive: isLive)
            LightningFlash(trigger: strikes)
        }
        .contentShape(Rectangle())
        .onTapGesture { tapOutside() }
        .accessibilityHidden(true)
    }

    /// The same sky for the same game, so a filmstrip repeats.
    private var fireworksSeed: UInt64 {
        UInt64(max(0, summary.stats.shotsFired)) &* 131 &+ UInt64(max(0, summary.stats.hits)) &* 17 &+ 7
    }

    // MARK: The card

    private func card(_ frame: CueSheet.Frame, isLive: Bool) -> some View {
        let didWin = summary.didWin
        let cardIn = frame.hasStarted("card")
        let rise = didWin ? 1 : frame.progress("card")
        let armed = frame.hasStarted("arm")
        let statsIn = frame.progress("stats")
        return VStack(spacing: 16) {
            emblem(frame, isLive: isLive)
            title(frame)
            Text(subtitle)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            statsBlock(frame, isLive: isLive)
                .opacity(statsIn)
                .offset(y: 8 * (1 - statsIn))
            buttons(armed: armed)
        }
        .padding(26)
        .frame(maxWidth: 390)
        .hudPanel(cornerRadius: 32)
        .overlay {
            if !didWin, rise < 1 {
                SurfacingVeil(level: 1 - rise, cornerRadius: 32)
            }
        }
        .padding()
        .scaleEffect(didWin && !cardIn ? 0.88 : 1)
        .offset(y: didWin ? 0 : 40 * (1 - rise))
        .opacity(didWin ? (cardIn ? 1 : 0) : (rise > 0 ? 1 : 0))
        .allowsHitTesting(cardIn)
        .animation(Motion.Curve.heavy.policy(policy), value: cardIn)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape) { onClose() }
    }

    @ViewBuilder
    private func emblem(_ frame: CueSheet.Frame, isLive: Bool) -> some View {
        if summary.didWin {
            let trophy = frame.hasStarted("trophy")
            let bloom = sin(Double.pi * frame.progress("bloom", curve: Easing.linear))
            HStack(spacing: 6) {
                Image(systemName: "laurel.leading")
                    .font(.system(size: 40, weight: .semibold))
                    .rotationEffect(.degrees(trophy ? 0 : -30), anchor: .bottom)
                Image(systemName: "trophy.fill")
                    .font(.system(size: 62))
                    .scaleEffect(trophy ? 1 : 0.001)
                Image(systemName: "laurel.trailing")
                    .font(.system(size: 40, weight: .semibold))
                    .rotationEffect(.degrees(trophy ? 0 : 30), anchor: .bottom)
            }
            .foregroundStyle(Theme.goldLeaf)
            .glow(Theme.gold, radius: 16)
            .background {
                // The gold bloom behind the cup, swelling as it lands and settling again.
                Circle()
                    .fill(RadialGradient(colors: [Theme.gold.opacity(0.55), Theme.gold.opacity(0)], center: .center, startRadius: 0, endRadius: 80))
                    .frame(width: 160, height: 160)
                    .opacity(bloom)
            }
            .opacity(trophy ? 1 : 0)
            .animation(Motion.Curve.slam.policy(policy), value: trophy)
            .accessibilityHidden(true)
        } else {
            SinkingShip(isLive: isLive)
                .frame(width: 230, height: 110)
        }
    }

    private func title(_ frame: CueSheet.Frame) -> some View {
        let didWin = summary.didWin
        let sweep: Double? = frame.isActive("sweep") ? frame.progress("sweep", curve: Easing.linear) : nil
        return KineticHeadline(
            text: didWin ? "VICTORY" : "DEFEAT",
            size: 44,
            weight: .black,
            style: .drop,
            tint: didWin ? AnyShapeStyle(Theme.goldLeaf) : AnyShapeStyle(Self.defeatLettering),
            progress: frame.progress("title", curve: Easing.linear),
            sweep: sweep,
            glow: didWin ? Theme.gold : Theme.hit
        )
        .accessibilityAddTraits(.isHeader)
        .accessibilityFocused($isTitleFocused)
    }

    private func statsBlock(_ frame: CueSheet.Frame, isLive: Bool) -> some View {
        let stats = summary.stats
        let isStacked = dynamicTypeSize.isAccessibilitySize
        let roll: CountingStat.Roll = !isLive || policy.collapsesSequences || isSkipped
            ? .done
            : (frame.hasStarted("stats") ? .rolling : .waiting)
        let statsLayout = isStacked ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 0))
        return VStack(spacing: 12) {
            statsLayout {
                CountingStat(title: "Shots", value: stats.shotsFired, roll: roll)
                if !isStacked {
                    Divider().frame(height: 34)
                }
                CountingStat(title: "Hits", value: stats.hits, roll: roll)
                if !isStacked {
                    Divider().frame(height: 34)
                }
                if let accuracy = stats.accuracy {
                    CountingStat(title: "Accuracy", value: Int((accuracy * 100).rounded()), suffix: "%", roll: roll)
                } else {
                    CountingStat(title: "Accuracy", value: nil, roll: roll)
                }
            }
            if let before = summary.ratingBefore, let after = summary.ratingAfter {
                Divider()
                    .padding(.horizontal, 24)
                RatingStat(from: before, to: after, delta: summary.ratingDelta, isBest: summary.isPersonalBest, roll: roll)
            }
            if let run = summary.winningRun {
                WinningRunChip(count: run)
            }
        }
        .padding(.vertical, 12)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func buttons(armed: Bool) -> some View {
        let halo = summary.didWin ? Theme.gold : Theme.hit
        return VStack(spacing: 10) {
            Button { onRematch() } label: {
                Label("Rematch", systemImage: "arrow.counterclockwise")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .primaryActionStyle()
            .tint(summary.didWin ? Theme.amber : Theme.hit)
            .shadow(color: halo.opacity(armed ? 0.7 : 0), radius: 16)
            .pulse(on: armed)
            .animation(Motion.Curve.settle.policy(policy), value: armed)
            Button("View the Board") { onClose() }
                .buttonStyle(.bordered)
                .tint(.white)
            ShareResultButton(summary: summary)
                .buttonStyle(.bordered)
                .tint(.white)
        }
        .controlSize(.large)
        .padding(.top, 2)
    }

    private static let defeatLettering = LinearGradient(
        colors: [Color(white: 0.97), Color(red: 1.0, green: 0.55, blue: 0.5), Theme.hit],
        startPoint: .top,
        endPoint: .bottom
    )

    private var subtitle: String {
        let opponentName = summary.opponentName
        switch (summary.didWin, summary.reason) {
        case (true, .resignation): "\(opponentName) struck their colours."
        case (true, .timeout): "\(opponentName) ran out of time to move."
        case (true, _): "You sent the enemy fleet to the bottom."
        case (false, .resignation): "You resigned. There's always the next battle."
        case (false, .timeout): "You ran out of time to make your move."
        case (false, _): "\(opponentName) sank your entire fleet."
        }
    }
}

/// The dark scrim of a victory, climbing from the bottom of the screen as `progress` runs 0…1.
private struct RisingScrim: View {
    let progress: Double

    var body: some View {
        let edge = -0.3 + 1.3 * min(max(progress, 0), 1)
        let dark = Color.black.opacity(0.62)
        LinearGradient(
            stops: [
                Gradient.Stop(color: dark, location: 0),
                Gradient.Stop(color: dark, location: min(1, max(0, edge))),
                Gradient.Stop(color: dark.opacity(0), location: min(1, max(0, edge + 0.3))),
            ],
            startPoint: .bottom,
            endPoint: .top
        )
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Night falling over a lost battle: the scene beneath loses most of its colour (a grey layer in the
/// saturation blend mode, which keeps its luminance) and darkens as `progress` runs 0…1. No shader.
private struct Nightfall: View {
    let progress: Double

    var body: some View {
        let night = min(max(progress, 0), 1)
        ZStack {
            // Partial alpha in the colour itself, so the blend is a plain mix toward the grey.
            Color(white: 0.5, opacity: 0.6 * night)
                .blendMode(.saturation)
            Color.black
                .opacity(0.45 + 0.25 * night)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The sea-coloured veil the DEFEAT card surfaces through: water standing `level` (0…1) of the way
/// up the card with a foam line at its surface, draining as `level` falls.
private struct SurfacingVeil: View {
    let level: Double
    let cornerRadius: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let depth = proxy.size.height * min(max(level, 0), 1)
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle()
                    .fill(.white.opacity(0.45))
                    .frame(height: 2)
                LinearGradient(
                    colors: [Theme.seaGlow.opacity(0.92), Theme.seaTop.opacity(0.96), Theme.seaBottom.opacity(0.98)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: max(0, depth))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A big number that rolls up to its value, with a caption underneath. It rolls on `OneShotClock`
/// (60 frames a second at most, 30 in the reduced tier) and shows its final value at once in the
/// still tier and whenever sequences collapse.
struct CountingStat: View {
    /// Where the number is in its roll: not started (reads 0), rolling, or landed on its value.
    enum Roll: Equatable {
        case waiting
        case rolling
        case done
    }

    let title: String
    /// `nil` shows a dash.
    let value: Int?
    var suffix = ""
    var roll: Roll = .rolling
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        VStack(spacing: 2) {
            switch roll {
            case .rolling where !policy.collapsesSequences:
                OneShotClock(duration: FinaleBeat.statsRoll) { elapsed in
                    number(display(at: elapsed))
                }
            case .waiting:
                number(display(at: 0))
            default:
                number(display(at: FinaleBeat.statsRoll))
            }
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.map { "\($0)\(suffix)" } ?? "none")
    }

    private func number(_ text: String) -> some View {
        Text(text)
            .font(.title2.weight(.bold).monospacedDigit())
    }

    private func display(at elapsed: TimeInterval) -> String {
        guard let value else { return "—" }
        let progress = Easing.easeOut(elapsed / FinaleBeat.statsRoll)
        return "\(Int((Double(value) * progress).rounded()))\(suffix)"
    }
}

/// Rays of light turning slowly behind a victory: static in intensity (they never pulse), turning
/// once a minute at the ambience rate, and still in the recap and the still tier.
struct Sunburst: View {
    var color: Color = Theme.gold
    var rays = 18
    var isLive = true
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        // Without flashes the rays shine at half strength.
        let intensity = policy.allowsFlashes ? 1.0 : 0.5
        LoopClock(loop: .ambient, isLive: isLive) { seconds in
            let angle = seconds.map { Motion.cycle($0, period: 60) * 360 } ?? 0
            ZStack {
                AngularGradient(stops: Self.stops(color: color, rays: rays, opacity: 0.36 * intensity), center: .center, angle: .zero)
                    .rotationEffect(.degrees(angle))
                RadialGradient(colors: [color.opacity(0.45 * intensity), color.opacity(0)], center: .center, startRadius: 0, endRadius: 190)
            }
            .mask {
                RadialGradient(colors: [.white, .white.opacity(0.55), .white.opacity(0)], center: .center, startRadius: 30, endRadius: 340)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func stops(color: Color, rays: Int, opacity: Double) -> [Gradient.Stop] {
        var stops: [Gradient.Stop] = []
        let count = CGFloat(rays)
        for ray in 0..<rays {
            let start = CGFloat(ray) / count
            let middle = (CGFloat(ray) + 0.5) / count
            let end = CGFloat(ray + 1) / count
            stops.append(Gradient.Stop(color: color.opacity(opacity), location: start))
            stops.append(Gradient.Stop(color: color.opacity(opacity), location: middle))
            stops.append(Gradient.Stop(color: color.opacity(0), location: middle))
            stops.append(Gradient.Stop(color: color.opacity(0), location: end))
        }
        return stops
    }
}

/// A warship going down by the stern, with bubbles rising where it was: one Canvas at 30 frames a
/// second until the ship has settled, then still. Already settled in the recap and the still tier.
struct SinkingShip: View {
    var isLive = true

    var body: some View {
        Group {
            if isLive {
                OneShotClock(duration: SinkingShipScene.settleTime, frameInterval: Clocks.reducedFrameInterval) { elapsed in
                    scene(at: elapsed)
                }
            } else {
                scene(at: SinkingShipScene.settleTime)
            }
        }
        .accessibilityHidden(true)
    }

    private func scene(at time: TimeInterval) -> some View {
        Canvas { context, size in
            SinkingShipScene.draw(time: time, in: context, size: size)
        }
    }
}

/// The drawing of `SinkingShip`, as a function of time.
enum SinkingShipScene {
    /// Seconds until the ship is under and the first bubbles have risen.
    static let settleTime: TimeInterval = 4.5

    nonisolated static func draw(time: TimeInterval, in context: GraphicsContext, size: CGSize) {
        let t = CGFloat(time)
        let waterline = size.height * 0.62
        let progress = min(1, max(0, (t - 0.5) / 2.4))
        let sink = progress * progress * (3 - 2 * progress)
        let swell = sin(t * 2.2) * 2

        // The ship goes down by the stern and settles with its bow raised, the rest hidden below
        // the waterline.
        let hull = CGRect(x: size.width * 0.14, y: waterline - size.height * 0.4, width: size.width * 0.72, height: size.height * 0.5)
        let pivot = CGPoint(x: hull.minX + hull.width * 0.3, y: waterline)
        var ship = context
        ship.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: waterline + swell)))
        ship.translateBy(x: pivot.x, y: pivot.y + sink * size.height * 0.3 + swell * (1 + sink))
        ship.rotate(by: .degrees(Double(-26 * sink + sin(t * 1.4) * 1.5 * sink)))
        ship.translateBy(x: -pivot.x, y: -pivot.y)
        ship.fill(
            WarshipProfile().path(in: hull),
            with: .linearGradient(
                Gradient(colors: [Theme.hull, Theme.hullShadow, Theme.gunMetal]),
                startPoint: CGPoint(x: hull.midX, y: hull.minY),
                endPoint: CGPoint(x: hull.midX, y: hull.maxY)
            )
        )

        // The sea, in two moving layers.
        for layer in 0..<2 {
            let offset = CGFloat(layer) * 5
            var water = Path()
            water.move(to: CGPoint(x: 0, y: size.height))
            for x in stride(from: CGFloat(0), through: size.width + 4, by: 4) {
                let angle = x / size.width * 4 * .pi + t * (layer == 0 ? 1.6 : -2.1) + CGFloat(layer) * 1.3
                water.addLine(to: CGPoint(x: x, y: waterline + offset + swell + sin(angle) * 3))
            }
            water.addLine(to: CGPoint(x: size.width + 4, y: size.height))
            water.closeSubpath()
            context.fill(
                water,
                with: .linearGradient(
                    Gradient(colors: layer == 0 ? [Theme.seaGlow.opacity(0.9), Theme.seaBottom] : [Theme.seaTop, Theme.abyss.opacity(0.95)]),
                    startPoint: CGPoint(x: 0, y: waterline),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
        }

        // Bubbles once it's under.
        guard progress > 0.45 else { return }
        for index in 0..<9 {
            let cycle = (t * 0.7 + CGFloat(index) * 0.37).truncatingRemainder(dividingBy: 1)
            let x = size.width * (0.42 + 0.16 * sin(CGFloat(index) * 2.3)) + sin(t * 3 + CGFloat(index)) * 3
            let y = size.height - (size.height - waterline - 6) * cycle
            let radius = 1.5 + CGFloat(index % 3)
            context.stroke(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                with: .color(.white.opacity(0.6 * (1 - cycle))),
                lineWidth: 1
            )
        }
    }
}
