import SwiftUI

/// The game's palette: deep water, steel ships, fire and spray.
enum Theme {
    // Water
    static let seaTop = Color(red: 0.08, green: 0.33, blue: 0.58)
    static let seaBottom = Color(red: 0.03, green: 0.17, blue: 0.36)
    static let seaGlow = Color(red: 0.16, green: 0.49, blue: 0.76)
    static let abyss = Color(red: 0.02, green: 0.07, blue: 0.16)
    static let gridLine = Color.white.opacity(0.1)

    // Ships
    static let hull = Color(red: 0.80, green: 0.86, blue: 0.92)
    static let hullShadow = Color(red: 0.47, green: 0.55, blue: 0.65)
    static let deck = Color(red: 0.66, green: 0.73, blue: 0.81)
    static let gunMetal = Color(red: 0.30, green: 0.35, blue: 0.42)
    static let superstructure = Color(red: 0.89, green: 0.93, blue: 0.97)
    static let flightDeck = Color(red: 0.26, green: 0.30, blue: 0.36)
    static let submarine = Color(red: 0.22, green: 0.27, blue: 0.34)
    static let wreck = Color(red: 0.30, green: 0.15, blue: 0.13)
    static let charred = Color(red: 0.12, green: 0.07, blue: 0.07)

    // Fire, water and light
    static let hit = Color(red: 1.00, green: 0.33, blue: 0.24)
    static let flame = Color(red: 1.00, green: 0.68, blue: 0.22)
    static let ember = Color(red: 1.00, green: 0.87, blue: 0.45)
    static let spray = Color.white.opacity(0.88)
    static let reticle = Color(red: 0.40, green: 0.92, blue: 1.00)
    static let victory = Color(red: 0.32, green: 0.86, blue: 0.56)
    static let gold = Color(red: 1.00, green: 0.82, blue: 0.30)
    static let amber = Color(red: 1.00, green: 0.62, blue: 0.20)

    static let fire = LinearGradient(
        colors: [Color(red: 1.00, green: 0.50, blue: 0.22), Color(red: 0.90, green: 0.18, blue: 0.20)],
        startPoint: .top,
        endPoint: .bottom
    )

    static let goldLeaf = LinearGradient(
        colors: [Color(red: 1.00, green: 0.95, blue: 0.70), gold, Color(red: 0.93, green: 0.55, blue: 0.16)],
        startPoint: .top,
        endPoint: .bottom
    )

    /// Rows in lists laid over the ocean.
    static let rowBackground = Color(red: 0.62, green: 0.80, blue: 1.0).opacity(0.08)
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

    /// A dark, glassy instrument panel with a fine lit edge, for the battle HUD.
    func hudPanel(cornerRadius: CGFloat = 22) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background {
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(Color(red: 0.02, green: 0.06, blue: 0.14).opacity(0.45)))
        }
        .overlay {
            shape.strokeBorder(
                LinearGradient(
                    colors: [.white.opacity(0.28), Theme.reticle.opacity(0.14), .white.opacity(0.04)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
        }
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
    }

    /// A soft halo of `color` around the view's opaque pixels.
    func glow(_ color: Color, radius: CGFloat = 8) -> some View {
        shadow(color: color.opacity(0.7), radius: radius / 2)
            .shadow(color: color.opacity(0.45), radius: radius)
    }
}

/// The big red button. When `isArmed` it breathes, to say a target is locked in.
struct FireButtonStyle: ButtonStyle {
    var isArmed = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.heavy))
            .tracking(1.5)
            .foregroundStyle(.white)
            .padding(.horizontal, 26)
            .padding(.vertical, 15)
            .background {
                Capsule()
                    .fill(Theme.fire)
                    .overlay(
                        Capsule()
                            .fill(LinearGradient(colors: [.white.opacity(0.35), .clear], startPoint: .top, endPoint: .center))
                            .padding(2)
                    )
            }
            .overlay(Capsule().strokeBorder(.white.opacity(0.4), lineWidth: 1))
            .background {
                if isArmed && isEnabled {
                    ArmedHalo()
                }
            }
            .shadow(color: Theme.hit.opacity(isEnabled ? 0.6 : 0), radius: 14, y: 4)
            .scaleEffect(configuration.isPressed ? 0.93 : 1)
            .saturation(isEnabled ? 1 : 0.2)
            .opacity(isEnabled ? 1 : 0.45)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// Rings pulsing out of the Fire button while a target is locked.
private struct ArmedHalo: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Capsule()
                .stroke(Theme.flame, lineWidth: 2)
                .scaleEffect(pulse ? 1.35 : 1)
                .opacity(pulse ? 0 : 0.9)
            Capsule()
                .fill(Theme.hit.opacity(pulse ? 0.15 : 0.45))
                .blur(radius: 12)
                .scaleEffect(pulse ? 1.2 : 1.05)
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}
