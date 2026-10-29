import BattleshipCore
import CoreTransferable
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The shareable picture of a finished battle: VICTORY or DEFEAT, the opponent and the date, the
/// enemy's waters as they ended with the marks and the revealed fleet, Shots / Hits / Accuracy, the
/// rating news and the winning run, styled like the card. It is drawn by `ImageRenderer`, through
/// CoreGraphics, so it uses no material, no shader and no backdrop-dependent shadow: an opaque
/// `resultPanel` and a still `BoardView` under `ResultExport.policy`.
struct ResultCard: View {
    let summary: GameOverSummary
    var date = Date.now

    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.seaTop, Theme.seaBottom, Theme.abyss], startPoint: .top, endPoint: .bottom)
            RadialGradient(
                colors: [(summary.didWin ? Theme.gold : Theme.hit).opacity(0.22), .clear],
                center: .top,
                startRadius: 0,
                endRadius: 520
            )
            VStack(spacing: 18) {
                header
                if let board = summary.finalBoard {
                    finalBoard(board)
                        .frame(width: 300, height: 300)
                } else {
                    emblem
                        .frame(height: 150)
                }
                statsPanel
                Spacer(minLength: 0)
                footer
            }
            .padding(28)
        }
        .frame(width: ResultExport.size.width, height: ResultExport.size.height)
        .environment(\.colorScheme, .dark)
        .environment(\.motionPolicy, ResultExport.policy)
    }

    private var header: some View {
        VStack(spacing: 6) {
            Text(summary.didWin ? "VICTORY" : "DEFEAT")
                .displayFont(56, weight: .black)
                .foregroundStyle(summary.didWin ? AnyShapeStyle(Theme.goldLeaf) : AnyShapeStyle(Self.defeatLettering))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(summary.didWin ? "against \(summary.opponentName)" : "to \(summary.opponentName)")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text(date.formatted(date: .abbreviated, time: .omitted))
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
        }
        .multilineTextAlignment(.center)
    }

    /// The enemy's waters: every shot's mark, and the fleet as it was revealed.
    private func finalBoard(_ perspective: BattlePerspective) -> some View {
        BoardView(rules: perspective.rules, isWaterAnimated: false) { geometry in
            ForEach(perspective.knownEnemyShips, id: \.self) { ship in
                let rect = geometry.rect(for: ship).insetBy(dx: geometry.cell * 0.1, dy: geometry.cell * 0.1)
                ShipView(ship: ship, isSunk: perspective.isEnemyShipSunk(ship))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
            ForEach(perspective.myShots, id: \.target) { move in
                if let mark = perspective.targetMark(at: move.target) {
                    CellMarkView(mark: mark, cell: geometry.cell, showsHitGlow: mark == .hit)
                        .position(geometry.center(of: move.target))
                }
            }
        }
    }

    @ViewBuilder
    private var emblem: some View {
        if summary.didWin {
            HStack(spacing: 8) {
                Image(systemName: "laurel.leading")
                    .font(.system(size: 54, weight: .semibold))
                Image(systemName: "trophy.fill")
                    .font(.system(size: 84))
                Image(systemName: "laurel.trailing")
                    .font(.system(size: 54, weight: .semibold))
            }
            .foregroundStyle(Theme.goldLeaf)
        } else {
            SinkingShip(isLive: false)
                .frame(width: 300, height: 140)
        }
    }

    private var statsPanel: some View {
        let stats = summary.stats
        return VStack(spacing: 14) {
            HStack(spacing: 0) {
                statColumn("Shots", "\(stats.shotsFired)")
                divider
                statColumn("Hits", "\(stats.hits)")
                divider
                statColumn("Accuracy", stats.accuracy.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
            }
            if let before = summary.ratingBefore, let after = summary.ratingAfter {
                HStack(spacing: 8) {
                    Text("RATING")
                        .scaledFont(12, weight: .heavy, design: .rounded, relativeTo: .caption)
                        .tracking(1.4)
                        .foregroundStyle(Theme.secondaryText)
                    Text(after.formatted())
                        .font(.title3.weight(.bold).monospacedDigit())
                        .foregroundStyle(Theme.goldLeaf)
                    if let delta = summary.ratingDelta, after != before {
                        Text(delta >= 0 ? "+\(delta)" : "−\(-delta)")
                            .font(.subheadline.weight(.heavy).monospacedDigit())
                            .foregroundStyle(delta >= 0 ? Theme.victory : Theme.hit)
                    }
                    if summary.isPersonalBest {
                        PersonalBestRibbon()
                    }
                }
            }
            if let run = summary.winningRun {
                WinningRunChip(count: run)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .resultPanel()
    }

    private func statColumn(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(Theme.secondaryText)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(.white.opacity(0.18))
            .frame(width: 1, height: 36)
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "scope")
            Text("BATTLESHIPS")
                .tracking(2)
        }
        .scaledFont(13, weight: .heavy, design: .rounded, relativeTo: .footnote)
        .foregroundStyle(Theme.secondaryText)
    }

    private static let defeatLettering = LinearGradient(
        colors: [Color(white: 0.97), Color(red: 1.0, green: 0.55, blue: 0.5), Theme.hit],
        startPoint: .top,
        endPoint: .bottom
    )
}

/// How the result card is exported.
enum ResultExport {
    /// 540 × 675 points: 1080 × 1350 pixels at `scale`.
    static let size = CGSize(width: 540, height: 675)
    static let scale: CGFloat = 2
    /// What the card renders under: the still tier with shaders off, so `BoardView` draws its static
    /// water fill and nothing waits on a clock. (`MotionPolicy.screenshot` with shaders off; the spec
    /// calls this `.export`.)
    static let policy: MotionPolicy = {
        var policy = MotionPolicy.screenshot
        policy.tier = .still
        policy.allowsFlashes = false
        policy.allowsShake = false
        policy.allowsShaders = false
        policy.collapsesSequences = true
        return policy
    }()

    enum Failure: Error {
        case couldNotRender
    }

    /// Draws `summary`'s card at `scale` as PNG data. On tap, never ahead of time.
    @MainActor
    static func render(_ summary: GameOverSummary) throws -> Data {
        let renderer = ImageRenderer(content: ResultCard(summary: summary))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(size)
        renderer.isOpaque = true
        guard let image = renderer.uiImage, let data = image.pngData() else {
            throw Failure.couldNotRender
        }
        return data
    }
}

/// The result as something a `ShareLink` can offer: it renders the card when the share sheet asks
/// for the data, which is after the tap, not before.
struct ResultImage: Transferable, Sendable {
    let summary: GameOverSummary

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { image in
            try await MainActor.run {
                try ResultExport.render(image.summary)
            }
        }
        .suggestedFileName("Battleships result.png")
    }
}

/// "Share result" on the game-over card: a `ShareLink` for the rendered picture, labelled for
/// VoiceOver, with a symbol as the preview so nothing is drawn until the player taps.
struct ShareResultButton: View {
    let summary: GameOverSummary

    var body: some View {
        ShareLink(
            item: ResultImage(summary: summary),
            preview: SharePreview(
                summary.didWin ? "Victory over \(summary.opponentName)" : "Defeat by \(summary.opponentName)",
                image: Image(systemName: summary.didWin ? "trophy.fill" : "water.waves")
            )
        ) {
            Label("Share result", systemImage: "square.and.arrow.up")
                .font(.headline)
                .frame(maxWidth: .infinity)
        }
        .accessibilityLabel("Share result")
        .accessibilityHint("Shares a picture of this battle's result.")
    }
}

extension View {
    /// The card's opaque panel for export: a dark fill with a fine lit edge, no material, no shadow.
    func resultPanel(cornerRadius: CGFloat = 20) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background {
            shape.fill(Color(red: 0.02, green: 0.06, blue: 0.14).opacity(0.75))
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
    }
}
