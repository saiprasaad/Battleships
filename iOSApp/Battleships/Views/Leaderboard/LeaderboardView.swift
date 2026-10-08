import BattleshipAPI
import SwiftUI

/// The top captains by rating.
struct LeaderboardView: View {
    @Environment(AppModel.self) private var app
    @State private var entries: [LeaderboardEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showsSignIn = false

    var body: some View {
        NavigationStack {
            Group {
                if !app.isSignedIn {
                    ContentUnavailableView {
                        Label("Sign In to See Rankings", systemImage: "trophy")
                    } description: {
                        Text("Win online battles to climb the leaderboard.")
                    } actions: {
                        Button("Sign In") { showsSignIn = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else if entries.isEmpty, isLoading {
                    ProgressView()
                } else if entries.isEmpty, let errorMessage {
                    ContentUnavailableView {
                        Label("Leaderboard Unavailable", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else if entries.isEmpty {
                    ContentUnavailableView {
                        Label("No Rankings Yet", systemImage: "trophy")
                    } description: {
                        Text("Finish an online battle to get on the board.")
                    }
                } else {
                    List(entries) { entry in
                        LeaderboardRow(entry: entry, isYou: entry.player.id == app.session.account?.id)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Leaderboard")
            .refreshable { await load() }
            .task(id: app.session.account?.id) { await load() }
            .sheet(isPresented: $showsSignIn) { AuthSheet() }
        }
    }

    private func load() async {
        guard app.isSignedIn else {
            entries = []
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            entries = try await app.api.leaderboard()
            errorMessage = nil
        } catch is CancellationError {
        } catch {
            errorMessage = error.userMessage
        }
    }
}

private struct LeaderboardRow: View {
    let entry: LeaderboardEntry
    let isYou: Bool

    var body: some View {
        HStack(spacing: 14) {
            rank
                .frame(width: 34)
            OpponentAvatar(name: entry.player.username, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(isYou ? "\(entry.player.username) (you)" : entry.player.username)
                    .font(.headline)
                Text("\(entry.wins)W · \(entry.losses)L")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(entry.player.rating)")
                .font(.title3.weight(.semibold).monospacedDigit())
        }
        .padding(.vertical, 4)
        .listRowBackground(isYou ? Color.accentColor.opacity(0.12) : nil)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rank \(entry.rank), \(entry.player.username)\(isYou ? ", you" : ""), rating \(entry.player.rating), \(entry.wins) wins, \(entry.losses) losses")
    }

    @ViewBuilder
    private var rank: some View {
        switch entry.rank {
        case 1: medal(.yellow)
        case 2: medal(Color(white: 0.75))
        case 3: medal(.orange)
        default:
            Text("\(entry.rank)")
                .font(.headline.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func medal(_ color: Color) -> some View {
        Image(systemName: "medal.fill")
            .font(.title2)
            .foregroundStyle(color)
    }
}
