import BattleshipAPI
import SwiftUI

/// The top captains by rating.
struct LeaderboardView: View {
    @Environment(AppModel.self) private var app
    @State private var entries: [LeaderboardEntry] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var showsSignIn = false
    @State private var moderation: ModerationRequest?

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
                    List {
                        if entries.count >= 3 {
                            Podium(entries: Array(entries.prefix(3)), yourID: app.session.account?.id, moderation: $moderation)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                        ForEach(entries.count >= 3 ? Array(entries.dropFirst(3)) : entries) { entry in
                            let isYou = entry.player.id == app.session.account?.id
                            LeaderboardRow(entry: entry, isYou: isYou)
                                .playerContextMenu(isYou ? nil : entry.player, request: $moderation)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .scrollContentBackground(.hidden)
            .background { OceanBackdrop() }
            .navigationTitle("Leaderboard")
            .refreshable { await load() }
            .task(id: app.session.account?.id) { await load() }
            .sheet(isPresented: $showsSignIn) { AuthSheet() }
            .playerModeration($moderation)
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
        .listRowBackground(isYou ? Theme.reticle.opacity(0.14) : Color.clear)
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

/// The top three captains, on the winners' steps.
private struct Podium: View {
    let entries: [LeaderboardEntry]
    let yourID: UUID?
    @Binding var moderation: ModerationRequest?

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            step(entries[1], height: 74, color: Color(white: 0.8))
            step(entries[0], height: 104, color: Theme.gold)
            step(entries[2], height: 56, color: Color(red: 0.86, green: 0.55, blue: 0.32))
        }
        .padding(.top, 12)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }

    private func step(_ entry: LeaderboardEntry, height: CGFloat, color: Color) -> some View {
        let isYou = entry.player.id == yourID
        return VStack(spacing: 6) {
            if entry.rank == 1 {
                Image(systemName: "crown.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.goldLeaf)
                    .glow(Theme.gold, radius: 8)
                    .accessibilityHidden(true)
            }
            OpponentAvatar(name: entry.player.username, size: entry.rank == 1 ? 64 : 52)
                .overlay(Circle().strokeBorder(color, lineWidth: 2.5).padding(-4))
                .glow(color, radius: 8)
            Text(isYou ? "You" : entry.player.username)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(entry.player.rating)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
            ZStack(alignment: .top) {
                UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous)
                    .fill(LinearGradient(colors: [color.opacity(0.55), color.opacity(0.08)], startPoint: .top, endPoint: .bottom))
                    .overlay(
                        UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12, style: .continuous)
                            .stroke(color.opacity(0.5), lineWidth: 1)
                    )
                Text("\(entry.rank)")
                    .displayFont(26, weight: .black)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.top, 8)
            }
            .frame(height: height)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .playerContextMenu(isYou ? nil : entry.player, request: $moderation)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Rank \(entry.rank), \(entry.player.username)\(isYou ? ", you" : ""), rating \(entry.player.rating)")
    }
}
