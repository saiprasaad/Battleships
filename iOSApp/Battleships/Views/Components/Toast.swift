import SwiftUI

/// Short notices over the screen, one at a time: the newest replaces the one before. Errors stay
/// until dismissed; everything else drains away after its `duration`.
@MainActor
@Observable
final class ToastCenter {
    static let shared = ToastCenter()

    private(set) var current: Toast?
    @ObservationIgnored private var dismissal: Task<Void, Never>?

    init() {}

    /// Shows a toast, replacing any on screen. Errors have no timer: they stay until `dismiss()`,
    /// the player swipes them away, or another toast replaces them.
    func show(_ kind: Toast.Kind, _ message: String, duration: Duration = Toast.hold, action: Toast.Action? = nil) {
        dismissal?.cancel()
        dismissal = nil
        let toast = Toast(kind: kind, message: message, action: action, duration: kind == .error ? nil : duration)
        current = toast
        guard let hold = toast.duration else { return }
        let id = toast.id
        dismissal = Task { [weak self] in
            do {
                try await Task.sleep(for: hold)
            } catch {
                return   // replaced or dismissed
            }
            guard let self, self.current?.id == id else { return }
            self.current = nil
        }
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        current = nil
    }
}

struct Toast: Identifiable, Equatable {
    enum Kind {
        case success, warning, error, info
    }

    struct Action {
        let title: String
        let run: @MainActor () -> Void
    }

    /// How long a toast stays unless it is an error.
    static let hold: Duration = .seconds(3.2)

    let id = UUID()
    let kind: Kind
    let message: String
    let action: Action?
    /// How long it stays, or nil to stay until dismissed (errors).
    var duration: Duration? = Toast.hold

    /// `duration` in seconds, for the draining hairline.
    var seconds: TimeInterval? {
        guard let duration else { return nil }
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    static func == (lhs: Toast, rhs: Toast) -> Bool {
        lhs.id == rhs.id
    }
}

extension Toast.Kind {
    var symbol: String {
        switch self {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .info: "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .success: Theme.victory
        case .warning: Theme.amber
        case .error: Theme.hit
        case .info: Theme.reticle
        }
    }
}

extension View {
    /// Hosts the shared `ToastCenter`'s toast at the top of this view: once over the root `TabView`,
    /// and once inside every sheet's `NavigationStack`, since sheets present above the root overlay.
    func toastHost() -> some View {
        modifier(ToastHost())
    }
}

private struct ToastHost: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            ToastStack()
        }
    }
}

/// The current toast, sliding in from the top on `Motion.Curve.toast` and leaving on `Motion.Curve.dismiss`.
private struct ToastStack: View {
    @Environment(\.motionPolicy) private var policy

    var body: some View {
        let center = ToastCenter.shared
        ZStack(alignment: .top) {
            if let toast = center.current {
                ToastView(toast: toast)
                    .id(toast.id)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity.animation(Motion.Curve.dismiss.policy(policy))
                    ))
            }
        }
        .animation(Motion.Curve.toast.policy(policy), value: center.current?.id)
        .padding(.top, 6)
        .padding(.horizontal, 16)
    }
}

/// A capsule with an icon that bounces 100 ms after landing, the message, an optional action and a
/// hairline draining along the bottom for as long as it stays. Swipe it up to dismiss; VoiceOver
/// hears the message as it lands and can dismiss it with the escape gesture.
struct ToastView: View {
    enum Style {
        /// Glass, over the app's screens.
        case app
        /// The battle HUD's dark panel, edged in `tint`.
        case battle(tint: Color)
    }

    let toast: Toast
    var style: Style = .app
    /// Posts the message to VoiceOver as it lands. The battle banner passes `false` because the
    /// controller already announces its news with the right priority.
    var isSpoken = true

    @Environment(\.motionPolicy) private var policy
    @State private var drag: CGFloat = 0
    @State private var bounces = 0

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.kind.symbol)
                .font(.body.weight(.bold))
                .foregroundStyle(accent)
                .symbolEffect(.bounce, value: bounces)
                .accessibilityHidden(true)
            Text(toast.message)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let action = toast.action {
                Button(action.title) { action.run() }
                    .buttonStyle(.borderless)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(accent)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 18)
        .background { face }
        .overlay(alignment: .bottom) { hairline }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.35), radius: 16, y: 8)
        .offset(y: drag)
        .gesture(dismissDrag)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape) { ToastCenter.shared.dismiss() }
        .accessibilityAction(named: "Dismiss") { ToastCenter.shared.dismiss() }
        .task(id: toast.id) {
            if isSpoken {
                AccessibilityNotification.Announcement(toast.message).post()
            }
            try? await Task.sleep(for: .milliseconds(100))
            if policy.tier == .full, !Task.isCancelled {
                bounces += 1
            }
        }
    }

    private var accent: Color {
        switch style {
        case .app: toast.kind.tint
        case .battle(let tint): tint
        }
    }

    @ViewBuilder
    private var face: some View {
        switch style {
        case .app:
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Color(red: 0.02, green: 0.06, blue: 0.14).opacity(0.55)))
                .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1))
        case .battle(let tint):
            Capsule()
                .fill(Theme.abyss.opacity(0.85))
                .overlay(Capsule().strokeBorder(tint.opacity(0.55), lineWidth: 1))
        }
    }

    @ViewBuilder
    private var hairline: some View {
        if let seconds = toast.seconds {
            DrainingHairline(seconds: seconds, tint: accent)
                .padding(.horizontal, 14)
                .padding(.bottom, 3)
        }
    }

    private var dismissDrag: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let height = value.translation.height
                // Up follows the finger; down only gives a little.
                drag = height < 0 ? height : height * 0.15
            }
            .onEnded { value in
                if value.translation.height < -24 || value.predictedEndTranslation.height < -80 {
                    ToastCenter.shared.dismiss()
                } else {
                    withAnimation(Motion.Curve.release.policy(policy)) {
                        drag = 0
                    }
                }
            }
    }
}

/// A 2 pt line that drains from full to nothing over `seconds`: how long the toast has left.
private struct DrainingHairline: View {
    let seconds: TimeInterval
    let tint: Color
    @State private var isDrained = false

    var body: some View {
        Capsule()
            .fill(tint.opacity(0.8))
            .frame(height: 2)
            .scaleEffect(x: isDrained ? 0.001 : 1, y: 1, anchor: .leading)
            .animation(.linear(duration: seconds), value: isDrained)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .task { isDrained = true }
    }
}
