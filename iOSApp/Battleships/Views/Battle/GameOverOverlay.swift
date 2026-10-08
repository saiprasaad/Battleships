import BattleshipCore
import SwiftUI

/// The end-of-battle card: a gold sunburst and confetti for a win, a ship slipping beneath the
/// waves for a loss, and the player's shooting record.
struct GameOverOverlay: View {
    let didWin: Bool
    let reason: Outcome.Reason?
    let opponentName: String
    let stats: ShotStats
    let celebrates: Bool
    let onRematch: @MainActor () -> Void
    let onClose: @MainActor () -> Void

    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture { onClose() }
                .accessibilityHidden(true)

            if didWin {
                Sunburst()
                    .frame(width: 720, height: 720)
                    .offset(y: -170)
                    .opacity(hasAppeared ? 1 : 0)
            } else {
                RadialGradient(colors: [Theme.hit.opacity(0), Theme.hit.opacity(0.3)], center: .center, startRadius: 160, endRadius: 560)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }

            if celebrates {
                ConfettiView()
            }

            card
                .scaleEffect(hasAppeared ? 1 : 0.88)
                .opacity(hasAppeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(duration: 0.6, bounce: 0.3)) {
                hasAppeared = true
            }
        }
    }

    private var card: some View {
        VStack(spacing: 16) {
            emblem
            Text(didWin ? "VICTORY" : "DEFEAT")
                .font(.display(44, weight: .black))
                .foregroundStyle(didWin ? AnyShapeStyle(Theme.goldLeaf) : AnyShapeStyle(Self.defeatLettering))
                .glow(didWin ? Theme.gold : Theme.hit, radius: 14)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 0) {
                CountingStat(title: "Shots", value: stats.shotsFired)
                Divider().frame(height: 34)
                CountingStat(title: "Hits", value: stats.hits)
                Divider().frame(height: 34)
                if let accuracy = stats.accuracy {
                    CountingStat(title: "Accuracy", value: Int((accuracy * 100).rounded()), suffix: "%")
                } else {
                    CountingStat(title: "Accuracy", value: nil)
                }
            }
            .padding(.vertical, 12)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(spacing: 10) {
                Button { onRematch() } label: {
                    Label("Rematch", systemImage: "arrow.counterclockwise")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .primaryActionStyle()
                .tint(didWin ? Theme.amber : Theme.hit)
                Button("View the Board") { onClose() }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .controlSize(.large)
            .padding(.top, 2)
        }
        .padding(26)
        .frame(maxWidth: 390)
        .hudPanel(cornerRadius: 32)
        .padding()
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private var emblem: some View {
        if didWin {
            HStack(spacing: 6) {
                Image(systemName: "laurel.leading")
                    .font(.system(size: 40, weight: .semibold))
                Image(systemName: "trophy.fill")
                    .font(.system(size: 62))
                    .symbolEffect(.bounce, value: hasAppeared)
                Image(systemName: "laurel.trailing")
                    .font(.system(size: 40, weight: .semibold))
            }
            .foregroundStyle(Theme.goldLeaf)
            .glow(Theme.gold, radius: 16)
            .accessibilityHidden(true)
        } else {
            SinkingShip()
                .frame(width: 230, height: 110)
        }
    }

    private static let defeatLettering = LinearGradient(
        colors: [Color(white: 0.97), Color(red: 1.0, green: 0.55, blue: 0.5), Theme.hit],
        startPoint: .top,
        endPoint: .bottom
    )

    private var subtitle: String {
        switch (didWin, reason) {
        case (true, .resignation): "\(opponentName) struck their colours."
        case (true, .timeout): "\(opponentName) ran out of time to move."
        case (true, _): "You sent the enemy fleet to the bottom."
        case (false, .resignation): "You resigned. There's always the next battle."
        case (false, .timeout): "You ran out of time to make your move."
        case (false, _): "\(opponentName) sank your entire fleet."
        }
    }
}

/// A big number that counts up when it appears, with a caption underneath.
struct CountingStat: View {
    let title: String
    /// `nil` shows a dash.
    let value: Int?
    var suffix = ""
    @State private var start = Date()
    @State private var isCounting = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 2) {
            TimelineView(.animation(minimumInterval: nil, paused: !isCounting || reduceMotion)) { timeline in
                Text(display(at: timeline.date))
                    .font(.title2.weight(.bold).monospacedDigit())
            }
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.map { "\($0)\(suffix)" } ?? "none")
        .task {
            try? await Task.sleep(for: .seconds(1.8))
            isCounting = false
        }
    }

    private func display(at date: Date) -> String {
        guard let value else { return "—" }
        guard isCounting, !reduceMotion else { return "\(value)\(suffix)" }
        let progress = min(1, max(0, (date.timeIntervalSince(start) - 0.35) / 1.2))
        let eased = 1 - pow(1 - progress, 3)
        return "\(Int((Double(value) * eased).rounded()))\(suffix)"
    }
}

/// Rays of light turning slowly behind a victory.
struct Sunburst: View {
    var color: Color = Theme.gold
    var rays = 18
    @State private var spin = 0.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        AngularGradient(stops: Self.stops(color: color, rays: rays), center: .center, angle: .zero)
            .mask {
                RadialGradient(colors: [.white, .white.opacity(0.5), .white.opacity(0)], center: .center, startRadius: 30, endRadius: 340)
            }
            .rotationEffect(.degrees(spin))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 60).repeatForever(autoreverses: false)) {
                    spin = 360
                }
            }
    }

    private static func stops(color: Color, rays: Int) -> [Gradient.Stop] {
        var stops: [Gradient.Stop] = []
        let count = CGFloat(rays)
        for ray in 0..<rays {
            let start = CGFloat(ray) / count
            let middle = (CGFloat(ray) + 0.5) / count
            let end = CGFloat(ray + 1) / count
            stops.append(Gradient.Stop(color: color.opacity(0.3), location: start))
            stops.append(Gradient.Stop(color: color.opacity(0.3), location: middle))
            stops.append(Gradient.Stop(color: color.opacity(0), location: middle))
            stops.append(Gradient.Stop(color: color.opacity(0), location: end))
        }
        return stops
    }
}

/// A warship going down by the stern, with bubbles rising where it was.
struct SinkingShip: View {
    @State private var start = Date()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 1.6 : timeline.date.timeIntervalSince(start)
            Canvas { context, size in
                SinkingShip.draw(time: time, in: context, size: size)
            }
        }
        .accessibilityHidden(true)
    }

    private static func draw(time: TimeInterval, in context: GraphicsContext, size: CGSize) {
        let t = CGFloat(time)
        let waterline = size.height * 0.62
        let progress = min(1, max(0, (t - 0.5) / 2.6))
        let sink = progress * progress * (3 - 2 * progress)
        let swell = sin(t * 2.2) * 2

        // The ship, tilting bow-up as it goes down, hidden below the waterline.
        let hull = CGRect(x: size.width * 0.14, y: waterline - size.height * 0.4, width: size.width * 0.72, height: size.height * 0.5)
        let pivot = CGPoint(x: hull.midX, y: waterline)
        var ship = context
        ship.clip(to: Path(CGRect(x: 0, y: 0, width: size.width, height: waterline + swell)))
        ship.translateBy(x: pivot.x, y: pivot.y + sink * size.height * 0.55 + swell)
        ship.rotate(by: .degrees(Double(-20 * sink)))
        ship.translateBy(x: -pivot.x, y: -pivot.y)
        ship.fill(
            WarshipProfile().path(in: hull),
            with: .linearGradient(
                Gradient(colors: [Theme.hull, Theme.hullShadow, Theme.gunMetal]),
                startPoint: CGPoint(x: hull.midX, y: hull.minY),
                endPoint: CGPoint(x: hull.midX, y: hull.maxY)
            )
        )

        // The sea, in two moving layers.
        for layer in 0..<2 {
            let offset = CGFloat(layer) * 5
            var water = Path()
            water.move(to: CGPoint(x: 0, y: size.height))
            for x in stride(from: CGFloat(0), through: size.width + 4, by: 4) {
                let angle = x / size.width * 4 * .pi + t * (layer == 0 ? 1.6 : -2.1) + CGFloat(layer) * 1.3
                water.addLine(to: CGPoint(x: x, y: waterline + offset + swell + sin(angle) * 3))
            }
            water.addLine(to: CGPoint(x: size.width + 4, y: size.height))
            water.closeSubpath()
            context.fill(
                water,
                with: .linearGradient(
                    Gradient(colors: layer == 0 ? [Theme.seaGlow.opacity(0.9), Theme.seaBottom] : [Theme.seaTop, Theme.abyss.opacity(0.95)]),
                    startPoint: CGPoint(x: 0, y: waterline),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
        }

        // Bubbles once it's under.
        guard progress > 0.45 else { return }
        for index in 0..<9 {
            let cycle = (t * 0.7 + CGFloat(index) * 0.37).truncatingRemainder(dividingBy: 1)
            let x = size.width * (0.42 + 0.16 * sin(CGFloat(index) * 2.3)) + sin(t * 3 + CGFloat(index)) * 3
            let y = size.height - (size.height - waterline - 6) * cycle
            let radius = 1.5 + CGFloat(index % 3)
            context.stroke(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                with: .color(.white.opacity(0.6 * (1 - cycle))),
                lineWidth: 1
            )
        }
    }
}

/// Falling paper, for victories.
struct ConfettiView: View {
    private struct Piece {
        let x: CGFloat
        let delay: Double
        let speed: Double
        let sway: Double
        let spin: Double
        let size: CGFloat
        let color: Color
    }

    @State private var start = Date()
    @State private var pieces = ConfettiView.makePieces()

    private nonisolated static func makePieces() -> [Piece] {
        (0..<110).map { _ in
            Piece(
                x: .random(in: 0...1),
                delay: .random(in: 0...1.4),
                speed: .random(in: 0.18...0.32),
                sway: .random(in: 1.5...3.5),
                spin: .random(in: 2...7),
                size: .random(in: 7...13),
                color: [Color.yellow, .orange, .pink, Theme.reticle, Theme.victory, Theme.gold, .white].randomElement()!
            )
        }
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let elapsed = timeline.date.timeIntervalSince(start)
                for piece in pieces {
                    let age = elapsed - piece.delay
                    guard age > 0 else { continue }
                    let y = -20 + age * piece.speed * size.height
                    guard y < size.height + 20 else { continue }
                    let x = piece.x * size.width + sin(age * piece.sway) * 24
                    var copy = context
                    copy.translateBy(x: x, y: y)
                    copy.rotate(by: .radians(age * piece.spin))
                    let rect = CGRect(x: -piece.size / 2, y: -piece.size / 4, width: piece.size, height: piece.size / 2)
                    copy.fill(Path(rect), with: .color(piece.color))
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
