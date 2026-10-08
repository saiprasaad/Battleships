import SwiftUI

/// The game's palette: deep water, steel ships, fire and spray.
enum Theme {
    static let seaTop = Color(red: 0.08, green: 0.33, blue: 0.58)
    static let seaBottom = Color(red: 0.03, green: 0.17, blue: 0.36)
    static let abyss = Color(red: 0.02, green: 0.07, blue: 0.16)
    static let gridLine = Color.white.opacity(0.12)
    static let boardLabel = Color.white.opacity(0.6)

    static let hull = Color(red: 0.80, green: 0.86, blue: 0.92)
    static let hullShadow = Color(red: 0.52, green: 0.60, blue: 0.70)
    static let wreck = Color(red: 0.38, green: 0.22, blue: 0.22)

    static let hit = Color(red: 1.00, green: 0.33, blue: 0.24)
    static let flame = Color(red: 1.00, green: 0.68, blue: 0.22)
    static let spray = Color.white.opacity(0.88)
    static let reticle = Color(red: 0.40, green: 0.92, blue: 1.00)
    static let victory = Color(red: 0.32, green: 0.86, blue: 0.56)

    static let fire = LinearGradient(
        colors: [Color(red: 1.00, green: 0.50, blue: 0.22), Color(red: 0.90, green: 0.18, blue: 0.20)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// The full-screen backdrop behind a battle.
    static let battleBackdrop = LinearGradient(
        colors: [Color(red: 0.05, green: 0.17, blue: 0.33), abyss],
        startPoint: .top,
        endPoint: .bottom
    )
}

extension View {
    /// A floating surface for controls over the battle: Liquid Glass on iOS 26, a material before.
    @ViewBuilder
    func floatingSurface(cornerRadius: CGFloat = 22) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        #else
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        #endif
    }

    /// The style for a screen's main action: Liquid Glass on iOS 26, bordered-prominent before.
    @ViewBuilder
    func primaryActionStyle() -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            buttonStyle(.glassProminent)
        } else {
            buttonStyle(.borderedProminent)
        }
        #else
        buttonStyle(.borderedProminent)
        #endif
    }
}

/// The big red button.
struct FireButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .padding(.vertical, 14)
            .background(Theme.fire, in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .shadow(color: Theme.hit.opacity(isEnabled ? 0.55 : 0), radius: 12, y: 4)
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}
