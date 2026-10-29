import BattleshipCore
import SwiftUI

/// Beats the battle screen's controls share: keyframe lengths that live beside the views that play them.
enum BattleBeat {
    /// A primary button's recoil is seen before the navigation it triggers (the spec's `Timing.buttonHandoff`).
    static let handoff: TimeInterval = 0.18
}

/// The Fire bar's own beats.
private enum FireBeat {
    /// The muzzle flash: 80 ms up, the rest out.
    static let flash: TimeInterval = 0.24
    static let flashRise: TimeInterval = 0.08
    /// The readout going white as the shot leaves.
    static let readoutFlash: TimeInterval = 0.06
    /// The border highlight as the button arms.
    static let armHighlight: TimeInterval = 0.08
    /// The light sweep across the bar when the turn comes back.
    static let sweep: TimeInterval = 0.45
    /// One breath of the armed halo.
    static let haloPeriod: Double = 1.1
    /// The halo's first ring growing from tight against the capsule.
    static let haloArm: TimeInterval = 0.3
}

/// What the Fire bar's readout says: the spec's `FireState`, derived by the battle screen from the
/// controller (whose turn, the shell in the air, the apex wait, a misfire).
enum FireState: Equatable, Sendable {
    /// The enemy's turn.
    case standBy
    /// The player's turn: pick a target.
    case aiming
    /// The player's shell is in the air.
    case firing
    /// An online shot has waited at the apex longer than `Timing.apexTimeout`.
    case transmitting
    /// The request failed: the shell fizzled.
    case misfire

    var caption: String {
        switch self {
        case .standBy: "STAND BY"
        case .aiming: "TARGET"
        case .firing: "FIRING"
        case .transmitting: "TRANSMITTING…"
        case .misfire: "MISFIRE"
        }
    }

    var isInFlight: Bool {
        self == .firing || self == .transmitting
    }
}

/// The target readout and the Fire button. Firing kicks the capsule back (1.12) behind a muzzle
/// flash, jolts the bar, flips the caption to FIRING and the readout to the shot's colour; the
/// button publishes `.fireButton` so the shell's arc can leave from it.
struct FireBar: View {
    /// The cell lined up, or the one the shell in the air is heading for.
    let target: Coordinate?
    let state: FireState
    let canFire: Bool
    /// The player's shots so far: bumps as each leaves, for the flash, the recoil and the jolt.
    var shotsFired = 0
    /// Bumped when the turn comes back: the caption flips to TARGET under a sweep.
    var turnStings = 0
    let onFire: @MainActor () -> Void
    @Environment(\.motionPolicy) private var policy

    private static let cornerRadius: CGFloat = 28

    var body: some View {
        HStack(spacing: 14) {
            readout
            Spacer(minLength: 8)
            fireButton
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 18)
        .hudPanel(cornerRadius: Self.cornerRadius)
        .overlay { handoffSweep }
        // The whole bar jolts with the shot.
        .recoil(on: shotsFired, kick: 1)
        // At the very largest text sizes the bar would push the board off screen.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    // MARK: The readout

    private var readout: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(state.caption)
                .tracking(1.6)
                .scaledFont(11, weight: .heavy, design: .rounded, relativeTo: .caption2)
                .foregroundStyle(captionColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
                .animation(Motion.Curve.state.policy(policy), value: state)
            digits
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .animation(Motion.Curve.snap.policy(policy), value: shownTarget)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenReadout)
        .accessibilityHint(subtitle)
    }

    /// The target as "F7": its letter, and its number rolling as the aim moves. White for 60 ms as
    /// the shot leaves (with flashes), then the shot's colour for the flight.
    private var digits: some View {
        let flashes = policy.allowsFlashes
        return OneShot(trigger: shotsFired, duration: FireBeat.readoutFlash, curve: Easing.linear) { progress in
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                if let target = shownTarget {
                    Text(Coordinate.rowLabel(target.row))
                    Text(Coordinate.columnLabel(target.column))
                        .rollingNumber(target.column + 1)
                } else {
                    Text("– –")
                }
            }
            .displayFont(28, weight: .black, monospacedDigits: true)
            .foregroundStyle(readoutColor)
            .brightness(flashes && progress < 1 ? 0.6 * (1 - progress) : 0)
            .glow(glowColor, radius: 10)
        }
    }

    /// The readout shows a target on the player's turn and while their shell is in the air.
    private var shownTarget: Coordinate? {
        switch state {
        case .standBy: nil
        case .aiming, .firing, .transmitting, .misfire: target
        }
    }

    private var captionColor: Color {
        switch state {
        case .standBy, .aiming: Color.secondary
        case .firing: Theme.flame
        case .transmitting: Theme.amber
        case .misfire: Theme.hit
        }
    }

    private var readoutColor: Color {
        guard shownTarget != nil else { return Color.white.opacity(0.25) }
        switch state {
        case .standBy, .aiming: return Theme.reticle
        case .firing: return Theme.flame
        case .transmitting: return Theme.flame.opacity(0.6)
        case .misfire: return Theme.hit
        }
    }

    private var glowColor: Color {
        shownTarget == nil ? .clear : readoutColor
    }

    private var subtitle: String {
        switch state {
        case .standBy: "The enemy is taking their shot"
        case .aiming: target == nil ? "Tap a square in enemy waters" : "Tap it again or press Fire"
        case .firing: "Shell away"
        case .transmitting: "Waiting for the server…"
        case .misfire: "The shot didn't go through"
        }
    }

    private var spokenReadout: String {
        switch state {
        case .standBy: return "Stand by"
        case .aiming: return target.map { "Target \($0.notation)" } ?? "No target"
        case .firing: return target.map { "Firing at \($0.notation)" } ?? "Firing"
        case .transmitting: return "Transmitting"
        case .misfire: return "Misfire"
        }
    }

    // MARK: The button

    private var fireButton: some View {
        Button { onFire() } label: {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill")
                Text(state.isInFlight ? "FIRING" : "FIRE")
                    .contentTransition(.numericText())
                    .frame(minWidth: 58, alignment: .leading)
            }
            .animation(Motion.Curve.state.policy(policy), value: state.isInFlight)
        }
        .buttonStyle(FireButtonStyle(isArmed: canFire, haloStartsTight: true))
        .disabled(!canFire)
        .recoil(on: shotsFired, kick: 1.12)
        .background { MuzzleFlash(trigger: shotsFired) }
        .battleAnchor(.fireButton)
        .keyboardShortcut(.space, modifiers: [])
        .hoverEffect(.lift)
        .accessibilityLabel("Fire")
        .accessibilityHint(target.map { "Fires at \($0.notation)." } ?? "Aim at a square in enemy waters first.")
    }

    /// A band of light crossing the bar as the turn comes back; a faint wash without flashes.
    private var handoffSweep: some View {
        PanelSweep(trigger: turnStings, cornerRadius: Self.cornerRadius)
    }
}

/// A band of light crossing a panel left to right in `FireBeat.sweep` whenever `trigger` changes:
/// a 120 pt white gradient added as light, or a faint white wash where flashes are off.
struct PanelSweep: View {
    let trigger: Int
    let cornerRadius: CGFloat
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        let flashes = policy.allowsFlashes
        OneShot(trigger: trigger, duration: FireBeat.sweep, curve: Easing.linear) { progress in
            GeometryReader { proxy in
                if progress < 1 {
                    if flashes {
                        let band: CGFloat = 120
                        LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            .offset(x: -band + (proxy.size.width + band) * CGFloat(progress))
                            .blendMode(.plusLighter)
                    } else {
                        Color.white.opacity(0.08 * sin(.pi * progress))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The muzzle flash behind the Fire capsule: two gradient capsules, white core to flame rim, added
/// as light, up in 80 ms and out over the rest of `FireBeat.flash`. Only where flashes are allowed.
private struct MuzzleFlash: View {
    let trigger: Int
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        if policy.allowsFlashes {
            OneShot(trigger: trigger, duration: FireBeat.flash, curve: Easing.linear) { progress in
                let rise = FireBeat.flashRise / FireBeat.flash
                let level: Double = progress >= 1 ? 0 : (progress < rise ? progress / rise : max(0, 1 - (progress - rise) / (1 - rise)))
                let bloom = CGFloat(1 - (1 - progress) * (1 - progress))
                ZStack {
                    Capsule()
                        .fill(EllipticalGradient(
                            colors: [.white.opacity(0.9 * level), Theme.flame.opacity(0.5 * level), Theme.flame.opacity(0)],
                            center: .center,
                            startRadiusFraction: 0,
                            endRadiusFraction: 0.8
                        ))
                        .padding(-10 - 26 * bloom)
                    Capsule()
                        .fill(EllipticalGradient(
                            colors: [Theme.ember.opacity(0.7 * level), Theme.hit.opacity(0)],
                            center: .center,
                            startRadiusFraction: 0.1,
                            endRadiusFraction: 0.8
                        ))
                        .padding(-4 - 14 * bloom)
                }
                .blendMode(.plusLighter)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }
}

/// The big red button. When `isArmed` it breathes, to say a target is locked in. The capsule sinks
/// under the thumb (0.96, 2 pt down, its shadow drawing in) on `Motion.Curve.press` and springs back
/// on `Motion.Curve.release`; below the full tier it only dims. Disabled, it desaturates over
/// `Motion.Curve.state` instead of snapping.
struct FireButtonStyle: ButtonStyle {
    var isArmed = false
    /// The halo's colour and the glow under the capsule.
    var tint: Color = Theme.hit
    /// The halo's first ring grows from tight against the capsule as the button arms (BAT-7).
    var haloStartsTight = false

    func makeBody(configuration: Configuration) -> some View {
        FireButtonFace(
            label: configuration.label,
            isPressed: configuration.isPressed,
            isArmed: isArmed,
            tint: tint,
            haloStartsTight: haloStartsTight
        )
    }
}

/// The face of `FireButtonStyle`. A view of its own so the environment (policy, enabled) is read
/// where SwiftUI installs it.
private struct FireButtonFace<ButtonLabel: View>: View {
    let label: ButtonLabel
    let isPressed: Bool
    let isArmed: Bool
    let tint: Color
    let haloStartsTight: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        let moves = policy.tier == .full
        let sinks = moves && isPressed
        let armed = isArmed && isEnabled
        label
            .font(.headline.weight(.heavy))
            .tracking(1.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 26)
            .padding(.vertical, 15)
            .background {
                Capsule()
                    .fill(Theme.fire)
                    .overlay(
                        Capsule()
                            .fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center))
                            .padding(2)
                    )
            }
            .overlay(Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 1))
            .overlay { ArmingHighlight(isArmed: armed) }
            .background {
                if armed {
                    ArmedHalo(tint: tint, startsTight: haloStartsTight)
                }
            }
            .shadow(color: tint.opacity(isEnabled ? (sinks ? 0.35 : 0.6) : 0), radius: sinks ? 6 : 14, y: sinks ? 2 : 4)
            .scaleEffect(sinks ? 0.96 : 1)
            .offset(y: sinks ? 2 : 0)
            .saturation(isEnabled ? 1 : 0.2)
            .opacity(isEnabled ? (!moves && isPressed ? 0.85 : 1) : 0.45)
            .animation(pressAnimation, value: isPressed)
            .animation(Motion.Curve.state.policy(policy), value: isEnabled)
    }

    private var pressAnimation: Animation {
        guard policy.tier == .full else { return Motion.Curve.reduced }
        return isPressed ? Motion.Curve.press : Motion.Curve.release
    }
}

/// The capsule's border lighting for `FireBeat.armHighlight` as the button arms: white with flashes,
/// the reticle colour without.
private struct ArmingHighlight: View {
    let isArmed: Bool
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        let color: Color = policy.allowsFlashes ? .white : Theme.reticle
        OneShot(trigger: isArmed, duration: FireBeat.armHighlight, curve: Easing.linear) { progress in
            Capsule()
                .strokeBorder(color.opacity(isArmed && progress < 1 ? 0.9 * (1 - progress) : 0), lineWidth: 2)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A ring pulsing out of the Fire button while a target is locked, over a soft radial glow (no
/// blur: a gradient-filled capsule). Runs at the ambient rate and holds still in the still tier.
/// `startsTight` grows the first ring from the capsule's edge as the button arms.
struct ArmedHalo: View {
    var tint: Color = Theme.hit
    var startsTight = false

    var body: some View {
        LoopClock(loop: .ambient) { seconds in
            let breath = seconds.map { Motion.cycle($0, period: FireBeat.haloPeriod) } ?? 0.3
            OneShot(trigger: 0, duration: FireBeat.haloArm, playsOnAppear: startsTight) { arm in
                let reach = CGFloat(Motion.easeOut(breath) * arm)
                ZStack {
                    Capsule()
                        .stroke(Theme.flame, lineWidth: 2)
                        .padding(-14 * reach)
                        .opacity(0.9 * (1 - breath))
                    Capsule()
                        .fill(EllipticalGradient(
                            colors: [tint.opacity(0.45 - 0.3 * breath), tint.opacity(0)],
                            center: .center,
                            startRadiusFraction: 0.35,
                            endRadiusFraction: 0.75
                        ))
                        .padding(-6 - 6 * CGFloat(breath))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Shown under a finished battle.
struct ResultBar: View {
    let didWin: Bool
    let stats: ShotStats
    let onSummary: @MainActor () -> Void
    let onRematch: @MainActor () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Bumped by each tap on Rematch, for its recoil.
    @State private var rematches = 0

    var body: some View {
        // At accessibility sizes the buttons go under the result, which has no room beside them.
        let isStacked = dynamicTypeSize.isAccessibilitySize
        let layout = isStacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            summary
            if !isStacked {
                Spacer(minLength: 8)
            }
            buttons
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .hudPanel(cornerRadius: 28)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .padding(.horizontal)
        .padding(.bottom, 6)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(didWin ? "VICTORY" : "DEFEAT")
                .displayFont(20, weight: .black)
                .foregroundStyle(didWin ? AnyShapeStyle(Theme.goldLeaf) : AnyShapeStyle(Theme.hit))
                .glow(didWin ? Theme.gold : Theme.hit, radius: 8)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(Phrase.count(stats.hits, "hit")) from \(Phrase.count(stats.shotsFired, "shot"))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button("Summary") { onSummary() }
                .buttonStyle(SecondaryButtonStyle())
            Button("Rematch") {
                rematches += 1
                onRematch()
            }
            .primaryActionStyle()
            .tint(didWin ? Theme.amber : Theme.hit)
            .recoil(on: rematches, kick: 1.06)
        }
    }
}

/// A transient headline such as "You sank their Cruiser!": the app's toast in its battle dress,
/// with the hit-streak chip when the shot extends a run. It stays silent and hidden from VoiceOver
/// because the controller already posts the news with its priority.
struct BattleBanner: View {
    let toast: Toast
    let isGoodNews: Bool
    /// The player's consecutive hits; a chip from two.
    var streak = 0

    var body: some View {
        let tint = isGoodNews ? Theme.victory : Theme.hit
        ToastView(toast: toast, style: .battle(tint: tint), isSpoken: false)
            .overlay(alignment: .topTrailing) {
                if streak >= 2 {
                    StreakChip(count: streak)
                        .offset(x: 6, y: -8)
                }
            }
            .accessibilityHidden(true)
    }
}

/// A button title that becomes a spinner while its action runs, without changing the button's size.
/// The two crossfade on `Motion.Curve.state`.
struct BusyLabel: View {
    let title: String
    let isBusy: Bool
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        Text(title)
            .opacity(isBusy ? 0 : 1)
            .overlay {
                if isBusy {
                    ProgressView()
                        .tint(.white)
                        .transition(.opacity)
                }
            }
            .animation(Motion.Curve.state.policy(policy), value: isBusy)
    }
}

/// Centres its content in the space available, and scrolls when the content is taller, as it can
/// be at large text sizes. `onTapOutside` runs for taps beside the content.
struct CenteredScrollView<Content: View>: View {
    private let content: Content
    private let onTapOutside: (@MainActor () -> Void)?

    init(@ViewBuilder content: () -> Content, onTapOutside: (@MainActor () -> Void)? = nil) {
        self.content = content()
        self.onTapOutside = onTapOutside
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                content
                    .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                    .background {
                        if let onTapOutside {
                            Color.clear
                                .contentShape(Rectangle())
                                .onTapGesture { onTapOutside() }
                                .accessibilityHidden(true)
                        }
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// The battle can't be shown: declined, called off, signed out, or gone. A calm sea with the reason
/// and the way back (OPN-1).
struct UnavailableCard: View {
    let reason: String
    let onBack: @MainActor () -> Void

    var body: some View {
        CenteredScrollView {
            EmptySeaView(title: "Battle Unavailable", message: reason, systemImage: "exclamationmark.triangle") {
                Button("Back to Battles") { onBack() }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .frame(maxWidth: 440)
            .padding()
        }
    }
}

/// Offered when the opponent has let their time to move run out.
struct ClaimVictoryCard: View {
    let opponentName: String
    let isSubmitting: Bool
    let onClaim: @MainActor () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isStacked = dynamicTypeSize.isAccessibilitySize
        let layout = isStacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 14))
        layout {
            Image(systemName: "hourglass.bottomhalf.filled")
                .font(.title2)
                .foregroundStyle(Theme.amber)
                .glow(Theme.amber, radius: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(opponentName) is out of time")
                    .font(.headline)
                Text("They haven't fired in days. You can take the win.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !isStacked {
                Spacer(minLength: 8)
            }
            Button { onClaim() } label: {
                BusyLabel(title: "Claim Victory", isBusy: isSubmitting)
            }
            .primaryActionStyle()
            .tint(Theme.amber)
            .disabled(isSubmitting)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .hudPanel(cornerRadius: 20)
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.amber.opacity(0.5), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

/// An incoming challenge, waiting for an answer. The first time a challenge is seen its Incoming
/// Transmission plays (OPN-4): the amber scope boots, its beam finds and locks a contact that swells
/// into the challenger, and the caption types itself out; Accept and Decline are live from the
/// first frame. A tap skips to the end; later looks show the card as it ends.
struct ChallengeCard: View {
    let opponentName: String
    let caption: String?
    let mode: GameMode?
    /// An answer is on its way to the server.
    let isSubmitting: Bool
    /// The challenge, so the transmission plays once per challenge; nil plays nothing.
    var gameID: UUID? = nil
    let onAccept: @MainActor () -> Void
    let onDecline: @MainActor () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.motionPolicy) private var policy
    @Environment(AppModel.self) private var app: AppModel?
    @State private var playsIntro = false
    @State private var isSkipped = false

    /// The transmission's beats: 1.5 s, buttons live throughout.
    private static let sheet = CueSheet([
        Cue(name: "card", start: 0, duration: 0.3),
        Cue(name: "boot", start: 0, duration: 0.3),
        Cue(name: "teletype", start: 0.3, duration: 0.56),
        Cue(name: "lock", start: 0.6),
        Cue(name: "avatar", start: 0.7, duration: 0.3),
        Cue(name: "name", start: 1.1, duration: 0.2),
        Cue(name: "badge", start: 1.3, duration: 0.2),
    ], total: 1.5)

    private static let captionFont = Font.system(.caption, design: .rounded).weight(.heavy)

    var body: some View {
        Group {
            if playsIntro {
                CuePlayer(
                    sheet: Self.sheet,
                    trigger: playsIntro,
                    isSkipped: isSkipped,
                    onCue: { cue in
                        if cue == "lock" {
                            app?.feedback.play(.aim)
                        }
                    }
                ) { frame in
                    card(frame)
                }
            } else {
                card(Self.sheet.frame(at: Self.sheet.total, collapsed: true))
            }
        }
        .onAppear {
            guard let gameID, let app, !policy.collapsesSequences, !app.settings.hasSeenChallengeIntro(of: gameID) else { return }
            app.settings.markChallengeIntroSeen(of: gameID)
            playsIntro = true
        }
    }

    private func card(_ frame: CueSheet.Frame) -> some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
        let boot = frame.progress("boot")
        let isLocked = frame.hasStarted("lock")
        let avatar = frame.progress("avatar")
        let fade = frame.progress("card")
        return CenteredScrollView {
            VStack(spacing: 18) {
                ZStack {
                    RadarScope(tint: Theme.amber, boot: boot, lockedContact: isLocked ? 0 : nil)
                        .frame(width: isLarge ? 110 : 170, height: isLarge ? 110 : 170)
                    OpponentAvatar(name: opponentName, size: isLarge ? 64 : 84)
                        .glow(Theme.amber, radius: 12)
                        .scaleEffect(0.3 + 0.7 * avatar)
                        .opacity(avatar)
                }
                .frame(height: isLarge ? 100 : 150)
                VStack(spacing: 6) {
                    TeletypeText(text: "INCOMING TRANSMISSION", progress: frame.progress("teletype", curve: Easing.linear), font: Self.captionFont)
                        .tracking(2)
                        .foregroundStyle(Theme.amber)
                        .multilineTextAlignment(.center)
                    Text("\(opponentName) challenges you!")
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)
                        .opacity(frame.progress("name"))
                    if let caption {
                        Text(caption)
                            .foregroundStyle(.secondary)
                            .opacity(frame.progress("name"))
                    }
                }
                if let mode {
                    Label {
                        Text("\(mode.displayName): \(mode.tagline)")
                    } icon: {
                        Image(systemName: "square.grid.3x3.fill")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .opacity(frame.progress("badge"))
                }
                let buttons = isLarge ? AnyLayout(VStackLayout(spacing: 12)) : AnyLayout(HStackLayout(spacing: 12))
                buttons {
                    Button(role: .destructive) { onDecline() } label: {
                        BusyLabel(title: "Decline", isBusy: isSubmitting)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("Accept & Deploy") { onAccept() }
                        .primaryActionStyle()
                        .tint(Theme.hit)
                }
                .controlSize(.large)
                .disabled(isSubmitting)
            }
            .padding(28)
            .frame(maxWidth: 440)
            .hudPanel(cornerRadius: 30)
            .padding()
            .opacity(fade)
        }
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { isSkipped = true })
    }
}

/// Matchmaking, or a challenge the other player hasn't answered yet.
struct WaitingCard: View {
    let isMatchmaking: Bool
    let opponentName: String
    let mode: GameMode?
    /// The withdrawal is on its way to the server.
    let isSubmitting: Bool
    let onCancel: @MainActor () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
        CenteredScrollView {
            VStack(spacing: 18) {
                Group {
                    if isMatchmaking {
                        RadarScope()
                    } else {
                        ZStack {
                            SonarPing()
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: isLarge ? 34 : 46))
                                .foregroundStyle(Theme.reticle)
                                .glow(Theme.reticle, radius: 10)
                                .accessibilityHidden(true)
                        }
                    }
                }
                .frame(width: isLarge ? 110 : 170, height: isLarge ? 110 : 170)
                Text(isMatchmaking ? "Searching for an Opponent" : "Challenge Sent")
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                Button(role: .destructive) { onCancel() } label: {
                    BusyLabel(title: isMatchmaking ? "Stop Searching" : "Withdraw Challenge", isBusy: isSubmitting)
                }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.large)
                .disabled(isSubmitting)
            }
            .padding(28)
            .frame(maxWidth: 440)
            .hudPanel(cornerRadius: 30)
            .padding()
        }
    }

    private var message: String {
        if isMatchmaking {
            let rules = mode.map { " \($0.displayName)" } ?? ""
            return "You'll be paired with the next captain looking for a\(rules) battle. We'll notify you when the fight is on."
        }
        return "Waiting for \(opponentName) to accept. We'll notify you when they do."
    }
}
