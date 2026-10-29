import SwiftUI

/// Shown once, on first launch: what the game is, and a button to begin. The reveal is a 1.4 s cue
/// sheet: the radar scope boots like an instrument and its glyph blooms, BATTLESHIPS rises as one
/// word, the three feature rows cascade in from the left, the horizon ship steams in to its mooring
/// and Set Sail rises last with its halo. Set Sail works from the first frame; a tap anywhere skips
/// to the end. Under VoiceOver and in the still tier everything is in place at once and the screen
/// fades in as one.
struct WelcomeView: View {
    let onStart: @MainActor () -> Void
    @Environment(\.motionPolicy) private var policy
    @State private var isSkipped = false
    @State private var sails = 0
    @State private var isShown = false
    @State private var isLeaving = false

    private struct Feature {
        let icon: String
        let title: String
        let detail: String
    }

    private static let features = [
        Feature(
            icon: "cpu",
            title: "Three computer admirals",
            detail: "From a Cadet who fires blind to an Admiral who calculates the odds on every shot."
        ),
        Feature(
            icon: "person.2.fill",
            title: "Challenge your friends",
            detail: "Play online at your own pace, with a notification when it's your move."
        ),
        Feature(
            icon: "trophy.fill",
            title: "Climb the leaderboard",
            detail: "Every online victory raises your rating. Beat a stronger captain to earn more."
        ),
    ]

    /// The reveal's beats, in seconds from the first frame.
    private static let sheet = CueSheet([
        Cue(name: "boot", start: 0, duration: 0.45),
        Cue(name: "ship", start: 0.2, duration: 1.2),
        Cue(name: "glyph", start: 0.25, duration: 0.5),
        Cue(name: "title", start: 0.3, duration: 0.45),
        Cue(name: "features", start: 0.5, duration: 0.4),
        Cue(name: "setSail", start: 0.9, duration: 0.4),
    ], total: 1.4)

    /// How long Set Sail's recoil is seen before the cover goes (the spec's `Timing.buttonHandoff`,
    /// to move there once the foundation owner adds the token).
    private static let handoff: TimeInterval = 0.18

    var body: some View {
        CuePlayer(sheet: Self.sheet, trigger: 0, isSkipped: isSkipped) { frame in
            content(frame)
        }
        .ignoresSafeArea(edges: .bottom)
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture { isSkipped = true }
        .opacity(isShown ? 1 : 0)
        .onAppear {
            // A collapsed sheet lands at once, so the whole screen fades in together instead.
            if policy.collapsesSequences {
                withAnimation(Motion.Curve.phase.policy(policy)) {
                    isShown = true
                }
            } else {
                isShown = true
            }
        }
    }

    private func content(_ frame: CueSheet.Frame) -> some View {
        let boot = frame.progress("boot", curve: Easing.linear)
        let glyph = frame.progress("glyph")
        let title = frame.progress("title")
        let ship = frame.progress("ship", curve: Easing.linear)   // the horizon eases the arrival itself
        let setSail = frame.progress("setSail")
        return ZStack {
            ParallaxOcean()

            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 0) {
                        ZStack {
                            RadarScope(boot: boot)
                                .frame(width: 190, height: 190)
                            Image(systemName: "scope")
                                .font(.system(size: 36, weight: .light))
                                .foregroundStyle(Theme.reticle)
                                // The bloom settles from 30 to 10 as the glyph pops.
                                .glow(Theme.reticle, radius: 30 - 20 * glyph)
                                .scaleEffect(0.6 + 0.4 * glyph)
                                .opacity(glyph)
                        }
                        .padding(.top, 28)
                        .accessibilityHidden(true)

                        VStack(spacing: 10) {
                            Text("BATTLESHIPS")
                                .displayFont(38, weight: .black)
                                .foregroundStyle(.white)
                                .glow(Theme.reticle, radius: 14 * title)
                                .minimumScaleFactor(0.6)
                                .lineLimit(1)
                                .accessibilityAddTraits(.isHeader)
                            Text("Hunt down the enemy fleet before it finds yours.")
                                .font(.title3.weight(.medium))
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.white.opacity(0.78))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 20)
                        .padding(.horizontal, 32)
                        .offset(y: 12 * (1 - title))
                        .opacity(title)

                        VStack(alignment: .leading, spacing: 18) {
                            ForEach(Array(Self.features.enumerated()), id: \.offset) { index, feature in
                                let row = frame.progress("features", index: index, stagger: Timing.Stagger.block)
                                WelcomeFeature(icon: feature.icon, title: feature.title, detail: feature.detail)
                                    .offset(x: -24 * (1 - row))
                                    .opacity(row)
                            }
                        }
                        .padding(.horizontal, 32)
                        .padding(.vertical, 28)
                        .frame(maxWidth: 520)
                    }
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)

                Button { setSailTapped() } label: {
                    Label("Set Sail", systemImage: "arrow.right")
                        .labelStyle(TrailingIconLabelStyle())
                        .frame(maxWidth: 360)
                }
                .buttonStyle(FireButtonStyle(isArmed: setSail >= 1))
                .recoil(on: sails, kick: 1.06)
                .padding(.horizontal, 32)
                .padding(.top, 8)
                .offset(y: 24 * (1 - setSail))
                .opacity(setSail)

                HorizonScene(shipPosition: 0.3, shipWidth: 120, shipEntrance: ship)
                    .frame(height: 84)
                    .padding(.top, 4)
            }
        }
    }

    /// The kick is seen, then the cover goes with the system's own transition.
    private func setSailTapped() {
        guard !isLeaving else { return }
        isLeaving = true
        sails += 1
        isSkipped = true
        let delay = policy.tier == .full ? Self.handoff : 0
        Task {
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
            }
            onStart()
        }
    }
}

private struct WelcomeFeature: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(Theme.reticle)
                .glow(Theme.reticle, radius: 6)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Title first, icon after: "Set Sail →".
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.title
            configuration.icon
        }
    }
}
