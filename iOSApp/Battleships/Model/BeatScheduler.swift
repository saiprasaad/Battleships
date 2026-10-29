import Foundation

/// Runs closures at offsets from `play()`: the choreography of a set piece whose beats change state,
/// play a sound or a haptic, or start an animation (an opening, a finale, a cast-off) from the model
/// side, with no view driving it. Everything happens on the main actor. "Tap to skip" and
/// backgrounding call `skip()`, which runs the cues left at once so the sequence lands in its end
/// state; `cancel()` abandons it without running anything more.
///
/// The view-side twin is `CueSheet` and `CuePlayer`: a sheet of named cues a view reads per frame.
/// Use the scheduler when a controller needs beats whether or not a view is on screen; use the
/// player when the picture is the thing.
///
/// Make it on the main actor (in `onAppear`, a `.task`, or a view's own `init`), not in a `@State`
/// default value. A scheduler can be played again once it has finished or been cancelled.
@MainActor
final class BeatScheduler {
    struct Cue {
        /// Seconds after `play()`.
        let at: TimeInterval
        let action: @MainActor () -> Void

        init(at: TimeInterval, action: @escaping @MainActor () -> Void) {
            self.at = at
            self.action = action
        }
    }

    /// In playing order: by offset, then as given.
    private let cues: [Cue]
    private let onFinish: (@MainActor () -> Void)?
    /// The first cue that hasn't run.
    private var nextIndex = 0
    private var task: Task<Void, Never>?
    private(set) var isPlaying = false

    init(_ cues: [Cue], onFinish: (@MainActor () -> Void)? = nil) {
        self.cues = cues.enumerated()
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            .map(\.element)
        self.onFinish = onFinish
    }

    /// Starts the scheduler (a no-op while it is playing). Cues fire in order; `onFinish` runs after the last.
    func play() {
        guard !isPlaying else { return }
        isPlaying = true
        nextIndex = 0
        let start = ContinuousClock.now
        task = Task { @MainActor [weak self] in
            var index = 0
            while let cue = self?.cue(at: index) {
                do {
                    try await Task.sleep(until: start + .seconds(cue.at), clock: .continuous)
                } catch {
                    return   // cancelled: skip() or cancel() took over
                }
                // A skip may have run this cue while the sleep was ending.
                guard !Task.isCancelled, let self, self.isPlaying, self.nextIndex == index else { return }
                self.nextIndex = index + 1
                cue.action()
                index += 1
            }
            self?.finish()
        }
    }

    /// Runs every remaining cue immediately, in order, then `onFinish`.
    func skip() {
        guard isPlaying else { return }
        task?.cancel()
        task = nil
        while nextIndex < cues.count {
            let cue = cues[nextIndex]
            nextIndex += 1
            cue.action()
        }
        finish()
    }

    /// Stops without running anything else, `onFinish` included.
    func cancel() {
        task?.cancel()
        task = nil
        isPlaying = false
    }

    private func cue(at index: Int) -> Cue? {
        guard isPlaying, index < cues.count else { return nil }
        return cues[index]
    }

    private func finish() {
        guard isPlaying else { return }
        isPlaying = false
        task = nil
        onFinish?()
    }
}
