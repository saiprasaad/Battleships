import UIKit

/// Tactile feedback on the UIKit generators: the fallback behind ``HapticEngine`` where Core
/// Haptics isn't available, so every event still has a feel.
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
        guard isEnabled() else { return }
        switch event {
        case .select:
            selection.selectionChanged()
        case .aim:
            selection.selectionChanged()
            // Firing usually comes next; waking the engine now keeps it in step with the shot.
            medium.prepare()
        case .place:
            light.impactOccurred()
        case .invalid:
            notification.notificationOccurred(.warning)
        case .fire:
            medium.impactOccurred()
            heavy.prepare()
            soft.prepare()
        case .incoming:
            light.impactOccurred()
        case .miss:
            soft.impactOccurred(intensity: 0.7)
        case .hit:
            heavy.impactOccurred()
        case .sunk:
            rigid.impactOccurred(intensity: 1)
            heavy.impactOccurred()
        case .victory:
            notification.notificationOccurred(.success)
        case .defeat:
            notification.notificationOccurred(.error)
        case .lift:
            light.impactOccurred(intensity: 0.7)
        case .rotate:
            light.impactOccurred()
        case .castOff:
            medium.impactOccurred()
        case .whistle:
            // The generators can't rise; the sound and the telegraph on screen carry it.
            break
        case .turnSting:
            selection.selectionChanged()
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(120))
                self?.selection.selectionChanged()
            }
        case .stamp:
            rigid.impactOccurred(intensity: 1)
        case .finalBlow:
            heavy.impactOccurred(intensity: 1)
        case .matchFound:
            light.impactOccurred()
        case .opening:
            medium.impactOccurred()
        case .toastSuccess:
            notification.notificationOccurred(.success)
        case .toastError:
            notification.notificationOccurred(.error)
        case .tick:
            // Too small for a generator; a counter stepping at this rate would only buzz.
            break
        case .lastShip:
            medium.impactOccurred()
        case .streak:
            light.impactOccurred()
        }
    }
}
