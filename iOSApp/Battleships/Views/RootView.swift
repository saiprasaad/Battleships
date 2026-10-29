import SwiftUI
import UIKit

struct RootView: View {
    private enum Tab: Hashable {
        case battles, leaderboard, profile
    }

    @Environment(AppModel.self) private var app
    @State private var selection: Tab = .battles
    /// Restarted on every tab switch, so the new tab's content rises into place.
    @State private var tabEntrance = EntranceClock()

    var body: some View {
        // The sky and sea follow the local time of day, re-read once a minute.
        SkyClock {
            TabView(selection: $selection) {
                LobbyView()
                    .tabEntrance(tabEntrance)
                    .tabItem { Label("Battles", systemImage: "scope") }
                    .tag(Tab.battles)
                    .badge(app.isSignedIn ? actionableCount : 0)

                LeaderboardView()
                    .tabEntrance(tabEntrance)
                    .tabItem { Label("Leaderboard", systemImage: "trophy") }
                    .tag(Tab.leaderboard)

                ProfileView()
                    .tabEntrance(tabEntrance)
                    .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                    .tag(Tab.profile)
            }
            // Every shader is compiled, and drawn once all but invisibly, so its pipeline is warm
            // before a battle needs it.
            .background { ShaderWarmup() }
            .task { await ShaderEffects.warmUp() }
            // Toasts float over every tab; sheets host their own, as they present above this overlay.
            .toastHost()
            .overlay(alignment: .topTrailing) {
                if app.settings.showsPerformanceOverlay {
                    MotionDebugOverlay()
                        .padding(.top, 4)
                        .padding(.trailing, 8)
                }
            }
        }
        // Every screen and sheet reads how much it may move from here.
        .motionPolicy(settings: app.settings)
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: showsWelcome) {
            WelcomeView {
                app.feedback.play(.navigate)
                app.settings.hasSeenWelcome = true
            }
            .onAppear { app.setAmbientScene(.welcome) }
            .onDisappear { app.setAmbientScene(.lobby) }
        }
        .onChange(of: selection) {
            tabEntrance.restart()
            app.feedback.play(.navigate)
        }
        .onChange(of: app.showsSessionExpired, initial: true) {
            if app.showsSessionExpired {
                explainSessionExpiry()
            }
        }
        .onChange(of: app.pendingRoute) {
            if app.pendingRoute != nil {
                selection = .battles
            }
        }
        .onChange(of: app.newGameRequest) {
            if app.newGameRequest != nil {
                selection = .battles
            }
        }
    }

    private var showsWelcome: Binding<Bool> {
        Binding(
            get: { !app.settings.hasSeenWelcome },
            set: { if !$0 { app.settings.hasSeenWelcome = true } }
        )
    }

    /// Tells the player why they were signed out. A sheet may well be up when it happens, and an alert
    /// attached to this view can't appear over one, so it goes on whatever is on top.
    private func explainSessionExpiry() {
        guard let presenter = Self.topmostViewController() else { return }
        guard presenter.presentedViewController == nil else {
            // Something on top is still going away; nothing can be presented until it has.
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                explainSessionExpiry()
            }
            return
        }
        app.showsSessionExpired = false
        let alert = UIAlertController(
            title: "You've Been Signed Out",
            message: "Your session expired. Sign in again to keep playing online. Games against the computer are unaffected.",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        presenter.present(alert, animated: true)
    }

    private static func topmostViewController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top
    }

    /// Online games waiting on the player: their move, or a challenge to answer.
    private var actionableCount: Int {
        app.online.summaries.filter { $0.isYourTurn || $0.isIncomingChallenge }.count
    }
}

private extension View {
    /// A tab's content as it is selected: an 8 pt rise with a short fade, replayed whenever `clock`
    /// restarts. Below the full tier it only fades.
    func tabEntrance(_ clock: EntranceClock) -> some View {
        modifier(TabEntrance(clock: clock))
    }
}

private struct TabEntrance: ViewModifier {
    let clock: EntranceClock
    @Environment(\.motionPolicy) private var policy
    @State private var isShown = false

    private static let rise: CGFloat = 8

    func body(content: Content) -> some View {
        content
            .opacity(isShown ? 1 : 0)
            .offset(y: isShown || policy.tier != .full ? 0 : Self.rise)
            .onAppear { reveal() }
            .onChange(of: clock) { replay() }
    }

    private func reveal() {
        withAnimation(Motion.Curve.phase.policy(policy)) {
            isShown = true
        }
    }

    /// Hides without animating, then rises on the next turn of the run loop.
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
