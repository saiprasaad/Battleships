import SwiftUI

/// A warship riding the swell, rocking gently. Under way (`course` other than 0) it rolls less and
/// lifts its bow a touch in the direction it is going. One `LoopClock(.scenery)`, so it holds still
/// with the policy.
struct SailingShip: View {
    /// −1…1: how fast the ship is moving and which way (negative is to the left). 0 is moored.
    var course: Double = 0

    /// The swell's phase in a still frame.
    private static let stillSeconds: TimeInterval = 0

    var body: some View {
        LoopClock(loop: .scenery) { seconds in
            let time = seconds ?? Self.stillSeconds
            let speed = min(1, abs(course))
            let heading: Double = course >= 0 ? 1 : -1
            WarshipProfile()
                .fill(
                    LinearGradient(
                        colors: [Theme.superstructure, Theme.hull, Theme.hullShadow, Theme.gunMetal],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                // The bow is to the right, so a ship steaming right lifts it with a turn to the left.
                .rotationEffect(.degrees(sin(time * 1.3) * 2.2 * (1 - 0.6 * speed) - 1.5 * speed * heading), anchor: .bottom)
                .offset(y: sin(time * 1.7) * 1.8)
        }
        .accessibilityHidden(true)
    }
}

/// The sea's surface with a warship on it, for the bottom edge of a banner or screen. The ship can
/// steam in from the left edge to its mooring (`shipEntrance` from 0 to 1), trailing a wake.
struct HorizonScene: View {
    /// Where the ship sits, from 0 (left) to 1 (right).
    var shipPosition: CGFloat = 0.62
    var shipWidth: CGFloat = 150
    /// The ship's arrival: 0 is off the left edge, 1 moored at `shipPosition`. The welcome's reveal
    /// drives it; everywhere else the ship is moored from the start.
    var shipEntrance: Double = 1

    var body: some View {
        GeometryReader { proxy in
            let arrival = Easing.easeOut(min(max(shipEntrance, 0), 1))
            let underway = 1 - arrival
            let shipHeight = shipWidth * 0.3
            let mooring = proxy.size.width * shipPosition - shipWidth / 2
            let x = -shipWidth + (mooring + shipWidth) * CGFloat(arrival)
            let waterline = -proxy.size.height * 0.24
            ZStack(alignment: .bottomLeading) {
                if underway > 0.001 {
                    ShipWake(strength: underway)
                        .frame(width: shipWidth * 0.9, height: 3)
                        .offset(x: x - shipWidth * 0.75, y: waterline - shipHeight * 0.2)
                }
                SailingShip(course: underway)
                    .frame(width: shipWidth, height: shipHeight)
                    .offset(x: x, y: waterline)
                WavesView(amplitude: 4)
                    .frame(height: proxy.size.height * 0.62)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A pale line of foam behind a ship under way, brightest at the stern.
private struct ShipWake: View {
    /// 0…1: how fast the ship is going.
    let strength: Double

    var body: some View {
        Capsule()
            .fill(LinearGradient(colors: [.white.opacity(0), .white.opacity(0.35)], startPoint: .leading, endPoint: .trailing))
            .opacity(strength)
    }
}
