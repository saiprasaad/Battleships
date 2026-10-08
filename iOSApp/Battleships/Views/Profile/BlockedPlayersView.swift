import BattleshipAPI
import SwiftUI

/// The players this player has blocked, each with a way to unblock them.
struct BlockedPlayersView: View {
    private static let explanation = "Blocked players can't challenge you, and you won't be matched with each other. Battles already under way carry on. To block someone, touch and hold their game in Battles or their name on the Leaderboard, or use the ··· menu in a battle."

    @Environment(AppModel.self) private var app
    @State private var isLoading = false
    @State private var unblocking: Set<UUID> = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            if !app.moderation.blockedPlayers.isEmpty {
                Section {
                    ForEach(app.moderation.blockedPlayers) { player in
                        BlockedPlayerRow(player: player, isUnblocking: unblocking.contains(player.id)) {
                            unblock(player)
                        }
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
        .alert("Couldn't Unblock", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    /// Loading, failure and empty states, shown while there's no one in the list.
    @ViewBuilder
    private var status: some View {
        let moderation = app.moderation
        if moderation.blockedPlayers.isEmpty {
            if isLoading || (!moderation.hasLoadedBlockedPlayers && moderation.loadError == nil) {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            } else if !moderation.hasLoadedBlockedPlayers, let error = moderation.loadError {
                ContentUnavailableView {
                    Label("Couldn't Load Blocked Players", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.bordered)
                }
            } else {
                ContentUnavailableView {
                    Label("No Blocked Players", systemImage: "hand.raised")
                } description: {
                    Text(Self.explanation)
                }
            }
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
                errorMessage = error.userMessage
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
            .buttonStyle(.bordered)
            .tint(.white)
            .disabled(isUnblocking)
            .accessibilityLabel("Unblock \(player.username)")
        }
        .padding(.vertical, 2)
    }
}
