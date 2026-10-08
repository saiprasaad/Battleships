import SwiftUI

/// Shown once, on first launch: what the game is, and a button to begin.
struct WelcomeView: View {
    let onStart: @MainActor () -> Void
    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            OceanBackdrop()

            VStack(spacing: 0) {
                Spacer(minLength: 24)

                ZStack {
                    RadarScope()
                        .frame(width: 230, height: 230)
                    Image(systemName: "scope")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(Theme.reticle)
                        .glow(Theme.reticle, radius: 10)
                }
                .scaleEffect(hasAppeared ? 1 : 0.6)
                .opacity(hasAppeared ? 1 : 0)

                VStack(spacing: 10) {
                    Text("BATTLESHIPS")
                        .font(.display(38, weight: .black))
                        .foregroundStyle(.white)
                        .glow(Theme.reticle, radius: 14)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                        .accessibilityAddTraits(.isHeader)
                    Text("Hunt down the enemy fleet before it finds yours.")
                        .font(.title3.weight(.medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.78))
                }
                .padding(.top, 22)
                .padding(.horizontal, 32)
                .offset(y: hasAppeared ? 0 : 20)
                .opacity(hasAppeared ? 1 : 0)

                Spacer(minLength: 24)

                VStack(alignment: .leading, spacing: 20) {
                    WelcomeFeature(
                        icon: "cpu",
                        title: "Three computer admirals",
                        detail: "From a Cadet who fires blind to an Admiral who calculates the odds on every shot."
                    )
                    WelcomeFeature(
                        icon: "person.2.fill",
                        title: "Challenge your friends",
                        detail: "Play online at your own pace, with a notification when it's your move."
                    )
                    WelcomeFeature(
                        icon: "trophy.fill",
                        title: "Climb the leaderboard",
                        detail: "Every online victory raises your rating. Beat a stronger captain to earn more."
                    )
                }
                .padding(.horizontal, 32)
                .frame(maxWidth: 520)
                .offset(y: hasAppeared ? 0 : 30)
                .opacity(hasAppeared ? 1 : 0)

                Spacer(minLength: 24)

                Button { onStart() } label: {
                    Label("Set Sail", systemImage: "arrow.right")
                        .labelStyle(TrailingIconLabelStyle())
                        .frame(maxWidth: 360)
                }
                .buttonStyle(FireButtonStyle(isArmed: true))
                .padding(.horizontal, 32)
                .opacity(hasAppeared ? 1 : 0)

                HorizonScene(shipPosition: 0.3, shipWidth: 130)
                    .frame(height: 96)
                    .padding(.top, 8)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .environment(\.colorScheme, .dark)
        .onAppear {
            withAnimation(.spring(duration: 0.9, bounce: 0.25).delay(0.1)) {
                hasAppeared = true
            }
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
