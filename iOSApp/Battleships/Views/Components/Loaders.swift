import SwiftUI

/// A small radar in place of a spinner: a 44 pt dish whose beam sweeps every 1.4 s and lights a
/// contact as it passes, beside captions that crossfade every two seconds. A failure stops the beam,
/// turned red; bumping `retry` spins it once more (Try Again). Still tier: the beam holds and the
/// first caption stays.
struct SonarLoader: View {
    var captions: [String] = ["Scanning the horizon…"]
    var tint: Color = Theme.reticle
    var isFailed = false
    /// What the captions say once `isFailed`.
    var failureCaption = "Couldn't reach the fleet"
    /// Bump to spin a stopped beam once, as Try Again is tapped.
    var retry = 0
    @Environment(\.motionPolicy) private var policy
    @State private var captionStart = Date()

    /// One turn of the beam, in seconds.
    static let period = 1.4
    /// How long each caption stays before the next.
    static let captionHold: TimeInterval = 2
    private static let size: CGFloat = 44
    private static let contact = UnitPoint(x: 0.68, y: 0.34)

    var body: some View {
        HStack(spacing: 12) {
            dish
                .frame(width: Self.size, height: Self.size)
            captionText
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isFailed ? failureCaption : "Loading")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var dish: some View {
        let color = isFailed ? Theme.hit : tint
        return ZStack {
            Circle()
                .fill(EllipticalGradient(colors: [color.opacity(0.2), color.opacity(0.04)], center: .center))
            Circle()
                .stroke(color.opacity(0.25), lineWidth: 1)
                .padding(Self.size / 4)
            LoopClock(loop: .ambient, isLive: !isFailed) { seconds in
                OneShot(trigger: retry, duration: Self.period, curve: { $0 }) { spin in
                    let turns = Self.turns(seconds: seconds, isFailed: isFailed, spin: spin)
                    let glow = seconds == nil && !isFailed
                        ? 1
                        : RadarContact.glow(forContactAt: RadarScope.fraction(of: Self.contact), turns: turns, period: Self.period)
                    ZStack {
                        SonarBeam(tint: color, turns: turns)
                            .clipShape(Circle())
                        RadarContact(tint: color, glow: glow)
                            .position(x: Self.size * Self.contact.x, y: Self.size * Self.contact.y)
                    }
                    .frame(width: Self.size, height: Self.size)
                }
            }
            Circle()
                .strokeBorder(color.opacity(0.5), lineWidth: 1)
        }
    }

    /// Where the beam points: sweeping while loading, held still (or spun once by `retry`) after a
    /// failure, resting in a still frame.
    private static func turns(seconds: Double?, isFailed: Bool, spin: Double) -> Double {
        if isFailed {
            return spin   // 1 at rest, which is three o'clock; 0 → 1 is one turn
        }
        guard let seconds else { return SonarBeam.stillTurns }
        return Motion.cycle(seconds, period: period)
    }

    @ViewBuilder
    private var captionText: some View {
        if isFailed {
            caption(failureCaption)
        } else if captions.count <= 1 || policy.holdsStill {
            caption(captions.first ?? "Loading…")
        } else {
            TimelineView(.periodic(from: captionStart, by: Self.captionHold)) { context in
                let index = Self.captionIndex(at: context.date, since: captionStart, count: captions.count)
                ZStack(alignment: .leading) {
                    caption(captions[index])
                        .id(index)
                        .transition(.opacity)
                }
                .animation(Motion.Curve.fade.policy(policy), value: index)
            }
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(Theme.secondaryText)
            .lineLimit(2)
    }

    private static func captionIndex(at date: Date, since start: Date, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let steps = Int(max(0, date.timeIntervalSince(start)) / captionHold)
        return steps % count
    }
}

/// An empty state over a calm sea: the horizon with a moored warship and one steady radar contact,
/// a title, a line of explanation and whatever actions make sense. The blocks enter one after
/// another (`Timing.Stagger.block`); below the full tier they fade.
struct EmptySeaView<Actions: View>: View {
    let title: String
    let message: String
    var systemImage: String
    let actions: () -> Actions
    @State private var entrance = EntranceClock()

    init(title: String, message: String, systemImage: String = "water.waves", @ViewBuilder actions: @escaping () -> Actions) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.actions = actions
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        VStack(spacing: 12) {
            CalmHorizon()
                .frame(height: 96)
                .frame(maxWidth: 360)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .entrance(entrance, step: 0)
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.white)
                .accessibilityAddTraits(.isHeader)
                .entrance(entrance, step: 1)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .entrance(entrance, step: 2)
            actions()
                .entrance(entrance, step: 3)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .padding(.horizontal, 16)
    }
}

extension EmptySeaView where Actions == EmptyView {
    init(title: String, message: String, systemImage: String = "water.waves") {
        self.init(title: title, message: message, systemImage: systemImage) { EmptyView() }
    }
}

/// The signed-out prompt, on the lobby and in the New Battle sheet: a calm horizon beside a line
/// about playing online and a Sign In button. At accessibility sizes it stacks.
struct SignInPrompt: View {
    var title = "Play online"
    var message = "Sign in to challenge friends and climb the leaderboard."
    let onSignIn: @MainActor () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isStacked = dynamicTypeSize.isAccessibilitySize
        let layout = isStacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout(spacing: 14))
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        layout {
            CalmHorizon(shipPosition: 0.6, shipWidth: 64)
                .frame(width: isStacked ? nil : 92, height: 60)
                .frame(maxWidth: isStacked ? CGFloat.infinity : nil)
                .clipShape(shape)
                .overlay(shape.strokeBorder(.white.opacity(0.12), lineWidth: 1))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !isStacked {
                Spacer(minLength: 0)
            }
            Button("Sign In") { onSignIn() }
                .buttonStyle(SecondaryButtonStyle())
                .controlSize(.small)
        }
        .padding(.vertical, 4)
    }
}

/// A calm sea under the hour's sky with a warship moored on it and one steady radar contact: the
/// picture behind empty states and the signed-out prompts.
struct CalmHorizon: View {
    var shipPosition: CGFloat = 0.64
    var shipWidth: CGFloat = 104
    /// The ship's arrival, as `HorizonScene` takes it; moored by default.
    var shipEntrance: Double = 1
    @Environment(\.skyPalette) private var palette

    var body: some View {
        ZStack(alignment: .topTrailing) {
            LinearGradient(colors: [palette.skyTop, palette.skyHorizon, palette.seaTop], startPoint: .top, endPoint: .bottom)
            HorizonScene(shipPosition: shipPosition, shipWidth: shipWidth, shipEntrance: shipEntrance)
                .frame(height: 72)
                .frame(maxHeight: .infinity, alignment: .bottom)
            ZStack {
                Circle()
                    .stroke(Theme.reticle.opacity(0.35), lineWidth: 1)
                    .frame(width: 18, height: 18)
                RadarContact(tint: Theme.reticle, glow: 1)
            }
            .padding(14)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
