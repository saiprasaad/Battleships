import BattleshipAPI
import SwiftUI

/// Something the player asked to do about another player, waiting for them to confirm.
struct ModerationRequest: Equatable {
    enum Action: Equatable {
        case report
        case block
        case unblock
    }

    let action: Action
    let player: PlayerSummary
    /// The game a report is about, if any.
    var gameID: UUID?
}

/// "Report <name>…" and "Block <name>…" (or "Unblock <name>" for someone already blocked), as
/// items in a menu or context menu. They only make the request; the `playerModeration(_:onBlocked:)`
/// modifier asks for confirmation and carries it out.
struct PlayerModerationButtons: View {
    let player: PlayerSummary
    var gameID: UUID?
    let isBlocked: Bool
    @Binding var request: ModerationRequest?

    var body: some View {
        Button("Report \(player.username)…", systemImage: "exclamationmark.bubble") {
            request = ModerationRequest(action: .report, player: player, gameID: gameID)
        }
        if isBlocked {
            Button("Unblock \(player.username)", systemImage: "hand.raised.slash") {
                request = ModerationRequest(action: .unblock, player: player)
            }
        } else {
            Button("Block \(player.username)…", systemImage: "hand.raised", role: .destructive) {
                request = ModerationRequest(action: .block, player: player)
            }
        }
    }
}

extension View {
    /// Report and block on a long press, for something showing another player. Without a player
    /// (a game against the computer, or the player's own entry) there's no menu.
    func playerContextMenu(_ player: PlayerSummary?, gameID: UUID? = nil, request: Binding<ModerationRequest?>) -> some View {
        modifier(PlayerContextMenu(player: player, gameID: gameID, request: request))
    }

    /// The dialogs that carry out a ``ModerationRequest`` (App Store guideline 1.2): reporting with
    /// a reason, blocking and unblocking, then a thank-you or an error. `onBlocked` runs once a
    /// block has gone through.
    func playerModeration(
        _ request: Binding<ModerationRequest?>,
        onBlocked: @escaping @MainActor (PlayerSummary) -> Void = { _ in }
    ) -> some View {
        modifier(PlayerModerationDialogs(request: request, onBlocked: onBlocked))
    }
}

private struct PlayerContextMenu: ViewModifier {
    @Environment(AppModel.self) private var app
    let player: PlayerSummary?
    let gameID: UUID?
    @Binding var request: ModerationRequest?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let player {
            let isBlocked = app.moderation.isBlocked(player.id)
            content.contextMenu {
                PlayerModerationButtons(player: player, gameID: gameID, isBlocked: isBlocked, request: $request)
            }
        } else {
            content
        }
    }
}

private struct PlayerModerationDialogs: ViewModifier {
    @Environment(AppModel.self) private var app
    @Binding var request: ModerationRequest?
    let onBlocked: @MainActor (PlayerSummary) -> Void
    /// The player just reported, for the thank-you.
    @State private var reported: PlayerSummary?
    @State private var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Report \(request?.player.username ?? "Player")?",
                isPresented: isPresented(.report),
                titleVisibility: .visible,
                presenting: request
            ) { request in
                ForEach(ReportReason.allCases, id: \.self) { reason in
                    Button(reason.displayName) { report(request, reason: reason) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("What's the problem? The people who run this server will look into it.")
            }
            .alert(
                "Block \(request?.player.username ?? "Player")?",
                isPresented: isPresented(.block),
                presenting: request
            ) { request in
                Button("Block", role: .destructive) { block(request.player) }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text("\(request.player.username) won't be able to challenge you, and you won't be matched with each other. Any challenges between you are withdrawn. Battles already under way carry on.")
            }
            .alert(
                "Unblock \(request?.player.username ?? "Player")?",
                isPresented: isPresented(.unblock),
                presenting: request
            ) { request in
                Button("Unblock") { unblock(request.player) }
                Button("Cancel", role: .cancel) {}
            } message: { request in
                Text("\(request.player.username) will be able to challenge you again, and you could be matched with each other.")
            }
            .alert(
                "Report Sent",
                isPresented: Binding(get: { reported != nil }, set: { if !$0 { reported = nil } }),
                presenting: reported
            ) { player in
                if !app.moderation.isBlocked(player.id) {
                    Button("Block \(player.username)") { offerToBlock(player) }
                }
                Button("OK", role: .cancel) {}
            } message: { _ in
                Text("Thanks for letting us know; the people who run this server will look into it.")
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(errorMessage ?? "")
            }
            .task(id: app.session.account?.id) {
                // Menus offer Unblock to players already blocked, so find out who they are.
                guard app.isSignedIn, !app.moderation.hasLoadedBlockedPlayers else { return }
                await app.moderation.loadBlockedPlayers()
            }
    }

    private func isPresented(_ action: ModerationRequest.Action) -> Binding<Bool> {
        Binding(
            get: { request?.action == action },
            set: { isPresented in
                // Leave alone a request that has already replaced this one.
                if !isPresented, request?.action == action {
                    request = nil
                }
            }
        )
    }

    private func report(_ request: ModerationRequest, reason: ReportReason) {
        Task {
            do {
                try await app.moderation.report(request.player, reason: reason, gameID: request.gameID)
                reported = request.player
            } catch {
                errorMessage = error.userMessage
            }
        }
    }

    private func block(_ player: PlayerSummary) {
        Task {
            do {
                try await app.moderation.block(player)
                onBlocked(player)
            } catch {
                errorMessage = error.userMessage
            }
        }
    }

    private func unblock(_ player: PlayerSummary) {
        Task {
            do {
                try await app.moderation.unblock(player)
            } catch {
                errorMessage = error.userMessage
            }
        }
    }

    /// Asks to block the player just reported. The thank-you has to finish going away first: another
    /// alert can't appear while one is still on screen.
    private func offerToBlock(_ player: PlayerSummary) {
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            request = ModerationRequest(action: .block, player: player)
        }
    }
}
