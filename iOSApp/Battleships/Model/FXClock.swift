import Foundation
import Observation

/// Maps wall-clock time to a board's effect time, so every burst, shell, smoke plume and sinking on
/// the board can freeze together (a hit-stop) or run slow (the finale) while SwiftUI's own animations
/// keep going.
///
/// Effect time starts at 0 when the clock is made and only ever moves forward. A hit-stop holds it
/// still for some wall time; slow motion stretches it. The two compose: a hit-stop during slow motion
/// wins while it lasts, and the slow motion then carries on for the time it had left, so
/// `slowMotion(scale: 0.35, for: 0.6)` always covers 0.6 s of unfrozen wall time with 0.21 s of
/// effect time, however many stops land inside it.
///
/// Make it on the main actor (from a controller, or a view's own `init` as `BattleView` makes its
/// controller), not in a `@State` default value, and date every call with the time the caller is
/// working from (the default is now). Owned by the battle controller and read by the boards'
/// `EffectTimeline`.
@MainActor
@Observable
final class FXClock {
    /// A stretch of wall time during which effect time stands still.
    private struct Freeze: Equatable, Sendable {
        var start: Date
        var end: Date
    }

    /// A stretch of running time (wall seconds with the freezes taken out) that plays at `scale`.
    private struct Stretch: Equatable, Sendable {
        var start: TimeInterval
        var end: TimeInterval
        var scale: Double
    }

    /// When effect time was 0.
    let origin: Date
    private var freezes: [Freeze] = []
    private var stretches: [Stretch] = []

    init(start: Date = Date()) {
        origin = start
    }

    /// Effect seconds at `date`: never less than at any earlier date, and 0 before the clock began.
    func time(at date: Date) -> TimeInterval {
        let running = runningTime(at: date)
        var slowed: TimeInterval = 0
        for stretch in stretches {
            let covered = min(running, stretch.end) - stretch.start
            if covered > 0 {
                slowed += covered * (1 - stretch.scale)
            }
        }
        return running - slowed
    }

    /// Whether a hit-stop holds effect time still at `date`.
    func isFrozen(at date: Date) -> Bool {
        freezes.contains { $0.start <= date && date < $0.end }
    }

    /// Whether a hit-stop holds effect time still right now.
    var isFrozen: Bool {
        isFrozen(at: Date())
    }

    /// Effect time stands still for `seconds` of wall time from `date`. Stops that overlap merge
    /// into one longer stop.
    func hitStop(_ seconds: TimeInterval, at date: Date = Date()) {
        guard seconds > 0 else { return }
        let start = max(date, origin)
        var freeze = Freeze(start: start, end: start.addingTimeInterval(seconds))
        var kept: [Freeze] = []
        for existing in freezes {
            if existing.end < freeze.start || existing.start > freeze.end {
                kept.append(existing)
            } else {
                freeze.start = min(freeze.start, existing.start)
                freeze.end = max(freeze.end, existing.end)
            }
        }
        kept.append(freeze)
        freezes = kept.sorted { $0.start < $1.start }
    }

    /// Effect time runs at `scale` (0.35 is slow, 1 is normal) for `seconds` of unfrozen wall time
    /// from `date`, then at 1 again. Where it overlaps an earlier slow motion, the newer one wins.
    func slowMotion(scale: Double, for seconds: TimeInterval, at date: Date = Date()) {
        guard seconds > 0 else { return }
        let start = runningTime(at: date)
        let stretch = Stretch(start: start, end: start + seconds, scale: max(0, scale))
        var kept: [Stretch] = []
        for existing in stretches {
            if existing.end <= stretch.start || existing.start >= stretch.end {
                kept.append(existing)
                continue
            }
            if existing.start < stretch.start {
                kept.append(Stretch(start: existing.start, end: stretch.start, scale: existing.scale))
            }
            if existing.end > stretch.end {
                kept.append(Stretch(start: stretch.end, end: existing.end, scale: existing.scale))
            }
        }
        kept.append(stretch)
        stretches = kept.sorted { $0.start < $1.start }
    }

    /// Wall seconds since the clock began, with every hit-stop taken out.
    private func runningTime(at date: Date) -> TimeInterval {
        let elapsed = max(0, date.timeIntervalSince(origin))
        var frozen: TimeInterval = 0
        for freeze in freezes {
            let covered = min(date, freeze.end).timeIntervalSince(max(origin, freeze.start))
            if covered > 0 {
                frozen += covered
            }
        }
        return elapsed - frozen
    }
}
