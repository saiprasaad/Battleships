import UIKit

/// Tactile feedback for the moments that matter in a battle.
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
        }
    }
}
