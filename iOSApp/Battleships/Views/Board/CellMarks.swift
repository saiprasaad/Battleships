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
    /// When every fire on the board flares (the finale's stamp beat, FIN-1), on the same clock as
    /// `time`; nil otherwise.
    var flareStart: Double?

    var body: some View {
        symbol(for: mark)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func symbol(for mark: CellMark) -> some View {
        if isMiniature {
            if mark == .miss {
                Circle()
                    .fill(miniatureColor)
                    .frame(width: cell * 0.5, height: cell * 0.5)
            } else {
                // A crater: a dark dot with an ember ring (BAT-5), which doesn't flicker.
                CraterDot(cell: cell, isSunk: mark == .sunk)
            }
        } else {
            switch mark {
            case .miss:
                SplashMark(cell: cell)
            case .hit:
                FlameMark(cell: cell, showsHalo: showsHitGlow, time: time, flare: FlameMark.flare(at: time, since: flareStart))
            case .sunk:
                FlameMark(cell: cell, scale: 0.7, showsHalo: false, time: time, flare: FlameMark.flare(at: time, since: flareStart))
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

/// A hit on the miniature: a blackened dot with an ember rim, red once the ship is down.
private struct CraterDot: View {
    let cell: CGFloat
    let isSunk: Bool

    var body: some View {
        let rim = isSunk ? Theme.hit : Theme.flame
        Circle()
            .fill(Color.black.opacity(0.75))
            .frame(width: cell * 0.5, height: cell * 0.5)
            .overlay(Circle().strokeBorder(rim.opacity(0.95), lineWidth: max(1, cell * 0.08)))
            .shadow(color: rim.opacity(0.8), radius: cell * 0.2)
    }
}

/// One clock for all the fires on a board, so a board full of hits redraws once a frame rather than
/// once per flame. It is `LoopClock(loop: .effects)`: 24 frames a second, held still (passing `nil`)
/// when nothing is burning and whenever the policy holds loops still.
struct FlameClock<Content: View>: View {
    let isBurning: Bool
    @ViewBuilder let content: (Double?) -> Content

    var body: some View {
        LoopClock(loop: .effects, isLive: isBurning) { seconds in
            // Shares the board's coordinates: marks inside are placed with `position`.
            ZStack(alignment: .topLeading) {
                content(seconds)
            }
        }
    }
}

/// A fire burning where a shell struck a ship. It flickers with `time` from the board's
/// ``FlameClock``, and holds still without it. `flare` (0…1) is the finale's flare: the halo grows
/// to 1.4× and the flame brightens, with flashes only.
struct FlameMark: View {
    let cell: CGFloat
    var scale: CGFloat = 1
    var showsHalo = true
    var time: Double?
    var flare: Double = 0
    /// Each fire flickers at its own pace.
    @State private var rhythm = FlameMark.makeRhythm()
    @Environment(\.motionPolicy) private var policy

    /// How long the finale's flare lasts, in seconds.
    static let flareLength: TimeInterval = 0.5

    nonisolated private static func makeRhythm() -> (phase: Double, speed: Double) {
        (.random(in: 0...(2 * .pi)), .random(in: 2.4...3.6))
    }

    /// The flare 0…1 at `time` for a flare that began at `start`: up at once, fading out over
    /// `flareLength`; 0 without a start, before it, or once it is over.
    static func flare(at time: Double?, since start: Double?) -> Double {
        guard let time, let start else { return 0 }
        let elapsed = time - start
        guard elapsed >= 0, elapsed < flareLength else { return 0 }
        return 1 - elapsed / flareLength
    }

    var body: some View {
        let flicker: Double = time.map { 0.5 + 0.5 * sin($0 * rhythm.speed * 2 * .pi + rhythm.phase) } ?? 0.5
        let flare: Double = policy.allowsFlashes ? min(1, max(0, self.flare)) : 0
        // Typed up front: arithmetic inside a modifier is what the type checker is slowest on.
        let haloScale: CGFloat = CGFloat((0.92 + 0.16 * flicker) * (1 + 0.4 * flare)) * (showsHalo ? 1 : 0.7)
        let emberSize: CGFloat = max(1, cell * 0.06 * scale)
        let flameX: CGFloat = CGFloat(1.04 - 0.1 * flicker)
        let flameY: CGFloat = CGFloat(0.94 + 0.14 * flicker)
        let glow: CGFloat = cell * CGFloat(0.12 + 0.1 * flare) * scale
        ZStack {
            if showsHalo || flare > 0 {
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
                    .scaleEffect(haloScale)
                    .opacity(showsHalo ? 1 : flare)
            }
            // Embers drifting up off the fire (BAT-5): three dots that rise and fade with the flicker.
            if let time, policy.allowsParticles {
                ForEach(0..<3, id: \.self) { index in
                    ember(index: index, time: time, size: emberSize)
                }
            }
            Image(systemName: "flame.fill")
                .font(.system(size: cell * 0.52 * scale))
                .foregroundStyle(LinearGradient(colors: [Theme.ember, Theme.flame, Theme.hit], startPoint: .top, endPoint: .bottom))
                .scaleEffect(x: flameX, y: flameY, anchor: .bottom)
                .shadow(color: Theme.flame.opacity(0.9), radius: glow)
        }
        .allowsHitTesting(false)
    }

    /// One ember, by its index: it sways as it rises and fades out over its cycle.
    private func ember(index: Int, time: Double, size: CGFloat) -> some View {
        let phase: Double = Motion.cycle(time + Double(index) * 0.37 + rhythm.phase, period: 1.1)
        let sway: Double = 0.12 * sin(phase * 2 * .pi + Double(index)) + (Double(index) - 1) * 0.1
        let x: CGFloat = cell * scale * CGFloat(sway)
        let y: CGFloat = -cell * scale * CGFloat(0.1 + 0.42 * phase)
        return Circle()
            .fill(index == 1 ? Theme.ember : Theme.flame)
            .frame(width: size, height: size)
            .offset(x: x, y: y)
            .opacity((1 - phase) * 0.9)
    }
}
