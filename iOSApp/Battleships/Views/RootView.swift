import SwiftUI

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
        .alert("You've Been Signed Out", isPresented: Bindable(app).showsSessionExpired) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your session expired. Sign in again to keep playing online. Games against the computer are unaffected.")
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

    /// Online games waiting on the player: their move, or a challenge to answer.
    private var actionableCount: Int {
        app.online.summaries.filter { $0.isYourTurn || $0.isIncomingChallenge }.count
    }
}
