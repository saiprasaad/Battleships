import BattleshipCore
import SwiftUI

/// The result of a shot, drawn in its cell.
struct CellMarkView: View {
    let mark: CellMark
    let cell: CGFloat
    /// A hit on a ship the player can't see yet gets a halo so it stands out on open water.
    var showsHitGlow = false
    /// The fleet miniature draws plain dots, which read better at that size.
    var isMiniature = false
    /// The board's ``FlameClock`` time, which makes fires flicker.
    var time: Double?

    var body: some View {
        symbol(for: mark)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func symbol(for mark: CellMark) -> some View {
        if isMiniature {
            Circle()
                .fill(miniatureColor)
                .frame(width: cell * 0.5, height: cell * 0.5)
                .shadow(color: mark == .miss ? .clear : Theme.hit, radius: cell * 0.2)
        } else {
            switch mark {
            case .miss:
                SplashMark(cell: cell)
            case .hit:
                FlameMark(cell: cell, showsHalo: showsHitGlow, time: time)
            case .sunk:
                FlameMark(cell: cell, scale: 0.7, showsHalo: false, time: time)
                    .opacity(0.8)
            }
        }
    }

    private var miniatureColor: Color {
        switch mark {
        case .miss: .white.opacity(0.7)
        case .hit: Theme.flame
        case .sunk: Theme.hit
        }
    }
}

/// Where a shell fell into open water.
private struct SplashMark: View {
    let cell: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.3), lineWidth: max(0.75, cell * 0.03))
                .frame(width: cell * 0.52, height: cell * 0.52)
            Circle()
                .fill(Color.white.opacity(0.9))
                .frame(width: cell * 0.18, height: cell * 0.18)
                .shadow(color: .white.opacity(0.7), radius: cell * 0.1)
        }
    }
}

/// One clock for all the fires on a board, so a board full of hits redraws once a frame rather than
/// once per flame. It stops when nothing is burning, under Reduce Motion and in Low Power Mode, and
/// passes `nil` then.
struct FlameClock<Content: View>: View {
    let isBurning: Bool
    @ViewBuilder let content: (Double?) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isStill = !isBurning || Motion.holdsStill(reduceMotion: reduceMotion)
        TimelineView(.animation(minimumInterval: 1 / 24, paused: isStill)) { timeline in
            // Shares the board's coordinates: marks inside are placed with `position`.
            ZStack(alignment: .topLeading) {
                content(isStill ? nil : Motion.seconds(timeline.date))
            }
        }
    }
}

/// A fire burning where a shell struck a ship. It flickers with `time` from the board's
/// ``FlameClock``, and holds still without it.
struct FlameMark: View {
    let cell: CGFloat
    var scale: CGFloat = 1
    var showsHalo = true
    var time: Double?
    /// Each fire flickers at its own pace.
    @State private var rhythm = FlameMark.makeRhythm()

    nonisolated private static func makeRhythm() -> (phase: Double, speed: Double) {
        (.random(in: 0...(2 * .pi)), .random(in: 2.4...3.6))
    }

    var body: some View {
        let flicker: Double = time.map { 0.5 + 0.5 * sin($0 * rhythm.speed * 2 * .pi + rhythm.phase) } ?? 0.5
        ZStack {
            if showsHalo {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Theme.flame.opacity(0.6), Theme.hit.opacity(0.25), Theme.hit.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: cell * 0.5
                        )
                    )
                    .frame(width: cell, height: cell)
                    .scaleEffect(0.92 + 0.16 * flicker)
            }
            Image(systemName: "flame.fill")
                .font(.system(size: cell * 0.52 * scale))
                .foregroundStyle(LinearGradient(colors: [Theme.ember, Theme.flame, Theme.hit], startPoint: .top, endPoint: .bottom))
                .scaleEffect(x: 1.04 - 0.1 * flicker, y: 0.94 + 0.14 * flicker, anchor: .bottom)
                .shadow(color: Theme.flame.opacity(0.9), radius: cell * 0.12 * scale)
        }
        .allowsHitTesting(false)
    }
}
