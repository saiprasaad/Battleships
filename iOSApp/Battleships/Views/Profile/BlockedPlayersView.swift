import BattleshipAPI
import SwiftUI

/// The players this player has blocked, each with a way to unblock them.
struct BlockedPlayersView: View {
    private static let explanation = "Blocked players can't challenge you, and you won't be matched with each other. Battles already under way carry on. To block someone, touch and hold their game in Battles or their name on the Leaderboard, or use the ··· menu in a battle."

    @Environment(AppModel.self) private var app
    @Environment(\.motionPolicy) private var policy
    @State private var isLoading = false
    @State private var unblocking: Set<UUID> = []

    var body: some View {
        List {
            if !app.moderation.blockedPlayers.isEmpty {
                Section {
                    ForEach(Array(app.moderation.blockedPlayers.enumerated()), id: \.element.id) { index, player in
                        BlockedPlayerRow(player: player, isUnblocking: unblocking.contains(player.id)) {
                            unblock(player)
                        }
                        .staggeredEntrance(index: index, trigger: 0)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Unblock", systemImage: "hand.raised.slash") { unblock(player) }
                                .tint(Theme.reticle)
                        }
                    }
                } footer: {
                    Text(Self.explanation)
                        .foregroundStyle(Theme.secondaryText)
                }
                .listRowBackground(Theme.rowBackground)
            }
        }
        .overlay { status }
        .scrollContentBackground(.hidden)
        .background { OceanBackdrop() }
        .navigationTitle("Blocked Players")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .onAppear { app.feedback.play(.navigate) }
    }

    /// Loading, failure and empty states, shown while there's no one in the list.
    @ViewBuilder
    private var status: some View {
        let moderation = app.moderation
        if moderation.blockedPlayers.isEmpty {
            Group {
                if isLoading || (!moderation.hasLoadedBlockedPlayers && moderation.loadError == nil) {
                    SonarLoader(captions: ["Hailing the fleet…"])
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                } else if !moderation.hasLoadedBlockedPlayers, let error = moderation.loadError {
                    EmptySeaView(title: "Couldn't Load Blocked Players", message: error) {
                        Button("Try Again") { Task { await load() } }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                } else {
                    EmptySeaView(title: "No Blocked Players", message: Self.explanation)
                }
            }
            .animation(Motion.Curve.state.policy(policy), value: isLoading)
        }
    }

    private func load() async {
        isLoading = true
        await app.moderation.loadBlockedPlayers()
        isLoading = false
    }

    private func unblock(_ player: PlayerSummary) {
        guard !unblocking.contains(player.id) else { return }
        unblocking.insert(player.id)
        Task {
            do {
                try await app.moderation.unblock(player)
            } catch {
                ToastCenter.shared.show(.error, "Couldn't unblock \(player.username). \(error.userMessage)")
                app.feedback.play(.toastError)
            }
            unblocking.remove(player.id)
        }
    }
}

private struct BlockedPlayerRow: View {
    let player: PlayerSummary
    let isUnblocking: Bool
    let onUnblock: @MainActor () -> Void

    var body: some View {
        HStack(spacing: 12) {
            OpponentAvatar(name: player.username, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(player.username)
                    .font(.headline)
                Text("Rating \(player.rating)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button { onUnblock() } label: {
                BusyLabel(title: "Unblock", isBusy: isUnblocking)
            }
            .buttonStyle(SecondaryButtonStyle())
            .controlSize(.small)
            .disabled(isUnblocking)
            .accessibilityLabel("Unblock \(player.username)")
        }
        .padding(.vertical, 2)
    }
}
