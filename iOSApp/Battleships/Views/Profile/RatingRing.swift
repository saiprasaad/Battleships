import SwiftUI

/// A thin gold ring around the profile avatar showing how far the rating has got toward the next
/// hundred, with a bright reticle tip, and two slimmer arcs outside it for the win/loss split. On
/// appear the ring draws itself clockwise from the top on `Motion.Curve.enter` and the arcs follow
/// a beat later; a rating change retargets the ring and flashes its tip; crossing a hundred
/// completes the ring, flashes gold and starts the next one from empty. Decorative (the header's
/// rating label says all of it in words), so it is hidden from VoiceOver; in the reduced and still
/// tiers it shows its final state after the short fade. No tier words: the server knows no ranks.
/// The widths and gaps scale with Dynamic Type.
struct RatingRing: View {
    let rating: Int
    let wins: Int
    let losses: Int
    /// The avatar's diameter; the ring sits just outside it.
    var diameter: CGFloat = 84

    @Environment(\.motionPolicy) private var policy
    @ScaledMetric(relativeTo: .body) private var ringWidth: CGFloat = 3
    @ScaledMetric(relativeTo: .body) private var arcWidth: CGFloat = 1.5
    @ScaledMetric(relativeTo: .body) private var gap: CGFloat = 6
    /// The fraction of the ring drawn: 0 before the entrance, then the rating's progress.
    @State private var shown: Double = 0
    @State private var arcsDrawn = false
    @State private var isVisible = false
    @State private var tipFlashes = 0
    @State private var isGold = false

    /// How far from the last hundred to the next, 0…1.
    static func progress(of rating: Int) -> Double {
        Double(((rating % 100) + 100) % 100) / 100
    }

    /// Points still to go to the next hundred, 1…100.
    static func pointsToNext(from rating: Int) -> Int {
        100 - ((rating % 100) + 100) % 100
    }

    /// The next hundred above `rating`.
    static func nextHundred(above rating: Int) -> Int {
        rating + pointsToNext(from: rating)
    }

    var body: some View {
        let ringSide = diameter + 2 * (gap + ringWidth)
        let arcSide = ringSide + 2 * (gap + arcWidth)
        let fraction = min(1, max(0, shown))
        let games = wins + losses
        let winShare = games > 0 ? Double(wins) / Double(games) : 0
        let arcs: Double = arcsDrawn ? 1 : 0
        ZStack {
            // The track, then the ring itself from the top, clockwise.
            Circle()
                .stroke(Theme.gold.opacity(0.18), lineWidth: ringWidth)
                .frame(width: ringSide, height: ringSide)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(isGold ? Theme.ember : Theme.gold, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: ringSide, height: ringSide)
                .glow(Theme.gold, radius: isGold ? 12 : 4)
            // The tip rides the ring's end.
            Circle()
                .fill(Theme.reticle)
                .frame(width: ringWidth * 2, height: ringWidth * 2)
                .glow(Theme.reticle, radius: 6)
                .pulse(on: tipFlashes, scale: 1.6)
                .offset(y: -ringSide / 2)
                .rotationEffect(.degrees(360 * fraction))
                .opacity(fraction > 0 ? 1 : 0)
            // Wins in green, then losses in red, around the outside.
            if games > 0 {
                Circle()
                    .trim(from: 0, to: winShare * arcs)
                    .stroke(Theme.victory.opacity(0.9), style: StrokeStyle(lineWidth: arcWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: arcSide, height: arcSide)
                Circle()
                    .trim(from: winShare, to: winShare + (1 - winShare) * arcs)
                    .stroke(Theme.hit.opacity(0.8), style: StrokeStyle(lineWidth: arcWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: arcSide, height: arcSide)
            }
        }
        .frame(width: arcSide, height: arcSide)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { enter() }
        .onChange(of: rating) { oldRating, newRating in
            retarget(from: oldRating, to: newRating)
        }
    }

    /// Draws the ring, then the arcs a beat later. Below the full tier: the final state, faded in.
    private func enter() {
        let target = Self.progress(of: rating)
        guard policy.tier == .full else {
            shown = target
            arcsDrawn = true
            withAnimation(Motion.Curve.reduced) {
                isVisible = true
            }
            return
        }
        isVisible = true
        withAnimation(Motion.Curve.enter) {
            shown = target
        }
        withAnimation(Motion.Curve.enter.delay(RingBeat.arcs)) {
            arcsDrawn = true
        }
    }

    /// Retargets the ring on a rating change and flashes the tip. Crossing a hundred upwards
    /// completes the lap, flashes gold, then starts the next ring from empty.
    private func retarget(from oldRating: Int, to newRating: Int) {
        let target = Self.progress(of: newRating)
        guard policy.tier == .full else {
            withAnimation(Motion.Curve.reduced) {
                shown = target
            }
            return
        }
        tipFlashes += 1
        guard newRating / 100 > oldRating / 100 else {
            withAnimation(Motion.Curve.counter) {
                shown = target
            }
            return
        }
        withAnimation(Motion.Curve.counter) {
            shown = 1
            isGold = policy.allowsFlashes
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(RingBeat.lap))
            // Back to empty without animating, then the next ring draws on the following turn.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                shown = 0
                isGold = false
            }
            Task { @MainActor in
                withAnimation(Motion.Curve.counter) {
                    shown = target
                }
            }
        }
    }
}

/// The ring's own beats, in seconds: the arcs follow the ring, and a completed lap holds before
/// the next ring starts.
private enum RingBeat {
    static let arcs: TimeInterval = 0.4
    static let lap: TimeInterval = 0.5
}
