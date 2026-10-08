import SwiftUI
import UIKit

struct RootView: View {
    private enum Tab: Hashable {
        case battles, leaderboard, profile
    }

    @Environment(AppModel.self) private var app
    @State private var selection: Tab = .battles

    var body: some View {
        TabView(selection: $selection) {
            LobbyView()
                .tabItem { Label("Battles", systemImage: "scope") }
                .tag(Tab.battles)
                .badge(app.isSignedIn ? actionableCount : 0)

            LeaderboardView()
                .tabItem { Label("Leaderboard", systemImage: "trophy") }
                .tag(Tab.leaderboard)

            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.crop.circle") }
                .tag(Tab.profile)
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: showsWelcome) {
            WelcomeView { app.settings.hasSeenWelcome = true }
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
