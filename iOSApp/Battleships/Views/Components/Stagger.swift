import SwiftUI

/// Restarts a set of entrances: bump it and every view entered on it plays in again.
struct EntranceClock: Equatable {
    var id = 0

    mutating func restart() {
        id += 1
    }
}

extension View {
    /// Enters this view when it appears and again whenever `trigger` changes: it rises `offset`
    /// points, grows from `scale` and fades in on `Motion.Curve.enter`, delayed `index × stagger`
    /// so a list settles row by row. Indexes past `cap` all use the cap's delay, so a long list
    /// still settles in well under a second. Under the reduced and still tiers it is a plain
    /// `Motion.Curve.reduced` fade: no offset, scale or delay.
    func staggeredEntrance(
        index: Int,
        trigger: some Equatable,
        offset: CGFloat = 14,
        scale: CGFloat = 1,
        stagger: TimeInterval = Timing.Stagger.row,
        cap: Int = Timing.Stagger.maxItems
    ) -> some View {
        modifier(StaggeredEntrance(index: index, trigger: trigger, offset: offset, scale: scale, stagger: stagger, cap: cap))
    }

    /// The entrance of the `step`th block of a screen (a welcome's title, copy and buttons; a
    /// podium's steps): offset, scale and opacity on `Motion.Curve.enter`, delayed
    /// `step × Timing.Stagger.block`, replayed when `clock` restarts.
    func entrance(_ clock: EntranceClock, step: Int) -> some View {
        staggeredEntrance(index: step, trigger: clock, offset: 14, scale: 0.96, stagger: Timing.Stagger.block, cap: Timing.Stagger.maxItems)
    }
}

private struct StaggeredEntrance<Trigger: Equatable>: ViewModifier {
    let index: Int
    let trigger: Trigger
    let offset: CGFloat
    let scale: CGFloat
    let stagger: TimeInterval
    let cap: Int
    @Environment(\.motionPolicy) private var policy
    @State private var isShown = false

    func body(content: Content) -> some View {
        let moves = policy.tier == .full
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown || !moves ? 0 : offset)
            .scaleEffect(isShown || !moves ? 1 : scale)
            .onAppear { reveal() }
            .onChange(of: trigger) { replay() }
    }

    private var delay: TimeInterval {
        Double(min(max(0, index), max(0, cap))) * stagger
    }

    private func reveal() {
        let animation = policy.tier == .full ? Motion.Curve.enter.delay(delay) : Motion.Curve.reduced
        withAnimation(animation) {
            isShown = true
        }
    }

    /// Hides without animating, then reveals on the next turn of the run loop so the entrance
    /// plays again from its start.
    private func replay() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isShown = false
        }
        Task { @MainActor in
            reveal()
        }
    }
}
