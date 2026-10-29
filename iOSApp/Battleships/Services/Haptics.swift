import UIKit

/// Tactile feedback on the UIKit generators: the fallback behind ``HapticEngine`` where Core
/// Haptics isn't available (iPad, the simulator), so every event still has a feel. The generators
/// can't rumble or ramp, so each score is approximated by the nearest taps.
@MainActor
final class Haptics: FeedbackPlayer {
    private let isEnabled: @MainActor () -> Bool
    private let selection = UISelectionFeedbackGenerator()
    private let light = UIImpactFeedbackGenerator(style: .light)
    private let medium = UIImpactFeedbackGenerator(style: .medium)
    private let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private let soft = UIImpactFeedbackGenerator(style: .soft)
    private let notification = UINotificationFeedbackGenerator()

    init(isEnabled: @escaping @MainActor () -> Bool) {
        self.isEnabled = isEnabled
    }

    func play(_ event: FeedbackEvent) {
        play(event, variation: .default)
    }

    /// Plays `event` after `variation.delay`, on the side `variation.isMine` says.
    func play(_ event: FeedbackEvent, variation: FeedbackVariation) {
        guard isEnabled() else { return }
        guard variation.delay > 0 else {
            playNow(event, variation: variation)
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(variation.delay))
            self?.playNow(event, variation: variation)
        }
    }

    /// Wakes the generators so the first tap of a battle isn't late.
    func prepare() {
        selection.prepare()
        medium.prepare()
        heavy.prepare()
    }

    private func playNow(_ event: FeedbackEvent, variation: FeedbackVariation) {
        guard isEnabled() else { return }
        let intensity = CGFloat(min(1, max(0, variation.intensity)))
        switch event {
        case .select, .navigate:
            selection.selectionChanged()
        case .aim:
            selection.selectionChanged()
            // Firing usually comes next; waking the engine now keeps it in step with the shot.
            medium.prepare()
            after(0.12) { $0.light.impactOccurred(intensity: 0.6 * intensity) }
        case .place:
            light.impactOccurred(intensity: intensity)
        case .invalid:
            notification.notificationOccurred(.warning)
        case .fire:
            medium.impactOccurred(intensity: intensity)
            heavy.prepare()
            soft.prepare()
        case .incoming:
            light.impactOccurred(intensity: 0.5 * intensity)
        case .miss:
            soft.impactOccurred(intensity: 0.7 * intensity)
        case .nearMiss:
            soft.impactOccurred(intensity: 0.7 * intensity)
            after(0.05) { $0.light.impactOccurred(intensity: 0.6 * intensity) }
        case .hit:
            if variation.isFinal {
                playFinale(intensity: intensity)
            } else if variation.isMine {
                heavy.impactOccurred(intensity: intensity)
            } else {
                playHitOwn(intensity: intensity)
            }
        case .hitOwn:
            if variation.isFinal {
                playFinale(intensity: intensity)
            } else {
                playHitOwn(intensity: intensity)
            }
        case .sunk:
            if variation.isFinal {
                playFinale(intensity: intensity)
            } else {
                playSunk(intensity: intensity, groans: !variation.isMine)
            }
        case .sunkOwn:
            if variation.isFinal {
                playFinale(intensity: intensity)
            } else {
                playSunk(intensity: intensity, groans: true)
            }
        case .finalBlow:
            playFinale(intensity: intensity)
        case .victory:
            notification.notificationOccurred(.success)
        case .defeat:
            notification.notificationOccurred(.error)
        case .lift:
            light.impactOccurred(intensity: 0.7 * intensity)
        case .rotate:
            light.impactOccurred(intensity: intensity)
            after(0.06) { $0.light.impactOccurred(intensity: intensity) }
        case .shuffle:
            // One light tap per ship, staggered like the sweep on screen.
            let taps = min(max(variation.count, 1), Timing.Stagger.maxItems)
            light.impactOccurred(intensity: 0.6 * intensity)
            for index in 1..<taps {
                after(Double(index) * Timing.Stagger.ship) { $0.light.impactOccurred(intensity: 0.6 * intensity) }
            }
        case .castOff:
            rigid.impactOccurred(intensity: intensity)
            after(0.09) { $0.rigid.impactOccurred(intensity: intensity) }
        case .whistle:
            // The generators can't rise; the sound and the telegraph on screen carry it.
            break
        case .turnSting:
            selection.selectionChanged()
            after(0.09) { $0.selection.selectionChanged() }
        case .theirTurn:
            soft.impactOccurred(intensity: 0.4 * intensity)
        case .stamp:
            rigid.impactOccurred(intensity: intensity)
        case .matchFound:
            light.impactOccurred(intensity: intensity)
            after(0.32) { $0.light.impactOccurred(intensity: intensity) }
        case .opening:
            heavy.impactOccurred(intensity: intensity)
            after(0.18) { $0.rigid.impactOccurred(intensity: 0.8 * intensity) }
        case .toastSuccess:
            notification.notificationOccurred(.success)
        case .toastError:
            notification.notificationOccurred(.error)
        case .tick:
            // Too small for a generator; a counter stepping at this rate would only buzz.
            break
        case .lastShip:
            if variation.isMine {
                medium.impactOccurred(intensity: intensity)
                after(0.18) { $0.light.impactOccurred(intensity: 0.7 * intensity) }
            } else {
                light.impactOccurred(intensity: 0.7 * intensity)
                after(0.18) { $0.medium.impactOccurred(intensity: intensity) }
            }
        case .streak:
            light.impactOccurred(intensity: 0.7 * intensity)
            after(0.07) { $0.light.impactOccurred(intensity: 0.7 * intensity) }
            after(0.14) { $0.light.impactOccurred(intensity: 0.8 * intensity) }
        case .burning:
            // A loop: sound only.
            break
        case .firework:
            light.impactOccurred(intensity: 0.6 * intensity)
        case .thunder:
            heavy.impactOccurred(intensity: intensity)
        }
    }

    /// Their shell on your hull: a heavy thud, then a soft one as the hull takes it.
    private func playHitOwn(intensity: CGFloat) {
        heavy.impactOccurred(intensity: 0.9 * intensity)
        after(0.06) { $0.soft.impactOccurred(intensity: 0.8 * intensity) }
    }

    /// The hit and three secondaries down the hull; a soft nudge for the groan of your own ship.
    private func playSunk(intensity: CGFloat, groans: Bool) {
        rigid.impactOccurred(intensity: intensity)
        heavy.impactOccurred(intensity: intensity)
        for step in 1...3 {
            after(Double(step) * Timing.secondaryStep) { $0.heavy.impactOccurred(intensity: (0.6 + 0.15 * CGFloat(step)) * intensity) }
        }
        if groans {
            after(Timing.listStart + 1.2) { $0.soft.impactOccurred(intensity: 0.6 * intensity) }
        }
    }

    /// The last landing: one heavy crack, then three echoes fading out.
    private func playFinale(intensity: CGFloat) {
        heavy.impactOccurred(intensity: intensity)
        after(0.5) { $0.medium.impactOccurred(intensity: 0.6 * intensity) }
        after(0.9) { $0.light.impactOccurred(intensity: 0.5 * intensity) }
        after(1.3) { $0.light.impactOccurred(intensity: 0.4 * intensity) }
    }

    /// Runs `tap` after `seconds`, if the generators are still wanted.
    private func after(_ seconds: TimeInterval, _ tap: @escaping @MainActor @Sendable (Haptics) -> Void) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, self.isEnabled() else { return }
            tap(self)
        }
    }
}
