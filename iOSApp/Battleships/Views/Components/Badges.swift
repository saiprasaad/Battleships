import BattleshipCore
import SwiftUI

/// A round avatar with the opponent's initial, or a chip for the computer.
struct OpponentAvatar: View {
    let name: String
    var isComputer = false
    var size: CGFloat = 40

    var body: some View {
        ZStack {
            Circle().fill(color.gradient)
            if isComputer {
                Image(systemName: "cpu")
                    .font(.system(size: size * 0.45, weight: .semibold))
            } else {
                Text(initial)
                    .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
            }
        }
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var initial: String {
        name.first.map { String($0).uppercased() } ?? "?"
    }

    /// A stable colour per name, so each opponent is recognisable at a glance.
    private var color: Color {
        if isComputer { return .indigo }
        let palette: [Color] = [.blue, .teal, .orange, .pink, .purple, .green, .red, .cyan, .mint, .brown]
        let hash = name.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7FFF_FFFF }
        return palette[hash % palette.count]
    }
}

/// "10×10" or "5×5".
struct ModeBadge: View {
    let mode: GameMode

    var body: some View {
        Text("\(mode.rules.boardSize)×\(mode.rules.boardSize)")
            .font(.caption2.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .accessibilityLabel("\(mode.displayName) rules")
    }
}

/// A big number with a caption underneath.
struct StatTile: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
                .contentTransition(.numericText())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// Shows whether live updates are flowing, as a single icon.
struct ConnectionBadge: View {
    let connection: OnlineGamesStore.Connection

    var body: some View {
        Image(systemName: connection == .offline ? "antenna.radiowaves.left.and.right.slash" : "antenna.radiowaves.left.and.right")
            .foregroundStyle(color)
            .symbolEffect(.pulse, options: .repeating, isActive: connection == .connecting)
            .accessibilityLabel("Live updates: \(label)")
    }

    private var label: String {
        switch connection {
        case .live: "connected"
        case .connecting: "connecting"
        case .offline: "offline"
        }
    }

    private var color: Color {
        switch connection {
        case .live: .green
        case .connecting: .orange
        case .offline: .secondary
        }
    }
}
