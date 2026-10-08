import SwiftUI

/// A warship riding the swell, rocking gently.
struct SailingShip: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            WarshipProfile()
                .fill(
                    LinearGradient(
                        colors: [Theme.superstructure, Theme.hull, Theme.hullShadow, Theme.gunMetal],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                .rotationEffect(.degrees(sin(time * 1.3) * 2.2), anchor: .bottom)
                .offset(y: sin(time * 1.7) * 1.8)
        }
        .accessibilityHidden(true)
    }
}

/// The sea's surface with a warship on it, for the bottom edge of a banner or screen.
struct HorizonScene: View {
    /// Where the ship sits, from 0 (left) to 1 (right).
    var shipPosition: CGFloat = 0.62
    var shipWidth: CGFloat = 150

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .bottomLeading) {
                SailingShip()
                    .frame(width: shipWidth, height: shipWidth * 0.3)
                    .offset(x: proxy.size.width * shipPosition - shipWidth / 2, y: -proxy.size.height * 0.3)
                WavesView(amplitude: 4)
                    .frame(height: proxy.size.height * 0.62)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
