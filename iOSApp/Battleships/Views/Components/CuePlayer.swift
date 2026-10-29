import SwiftUI

/// Plays a `CueSheet` from a change of `trigger` (and once on appearance), hands `content` a
/// `CueSheet.Frame` per tick, fires `onCue` once on the first frame at or after each cue's start
/// (for sounds, haptics and state changes), calls `onFinished` when the sheet reaches `total`, and
/// honours skipping: when the caller flips `isSkipped` the clock jumps so that the last
/// `Timing.openingSkip` seconds of the sheet play from there, and the cues passed over fire in
/// order on that frame, so the end state fades rather than pops.
///
/// Under `policy.collapsesSequences` (VoiceOver, the still tier, Effects = Minimal) and frozen
/// clocks the player renders one frame at `total`, fires every cue in order on it, and finishes.
///
/// Every player with a sheet longer than a second is wrapped by its caller in a tap target that
/// sets `isSkipped`.
struct CuePlayer<Trigger: Equatable, Content: View>: View {
    let sheet: CueSheet
    let trigger: Trigger
    let isSkipped: Bool
    let onCue: (@MainActor (String) -> Void)?
    let onFinished: (@MainActor () -> Void)?
    let content: (CueSheet.Frame) -> Content

    @Environment(\.motionPolicy) private var policy
    /// When the sheet began on the wall clock; nil before it plays and after it is landed.
    @State private var start: Date?
    /// How many cues, in sheet order, have fired this run.
    @State private var firedCount = 0
    @State private var isFinished = false

    init(
        sheet: CueSheet,
        trigger: Trigger,
        isSkipped: Bool = false,
        onCue: (@MainActor (String) -> Void)? = nil,
        onFinished: (@MainActor () -> Void)? = nil,
        @ViewBuilder content: @escaping (CueSheet.Frame) -> Content
    ) {
        self.sheet = sheet
        self.trigger = trigger
        self.isSkipped = isSkipped
        self.onCue = onCue
        self.onFinished = onFinished
        self.content = content
    }

    var body: some View {
        let landsAtOnce = policy.collapsesSequences || policy.holdsStill
        let isLive = start != nil && !isFinished
        TimelineView(.animation(minimumInterval: policy.effectsInterval, paused: !isLive)) { timeline in
            let elapsed = sheetTime(at: timeline.date)
            content(sheet.frame(at: elapsed, collapsed: policy.collapsesSequences))
                .onChange(of: elapsed, initial: true) { advance(to: elapsed) }
        }
        .motionBudgeted(isLive: isLive)
        .onAppear { begin(landsAtOnce: landsAtOnce) }
        .onChange(of: trigger) { begin(landsAtOnce: landsAtOnce) }
        .onChange(of: isSkipped) {
            if isSkipped {
                skip()
            }
        }
        .onChange(of: landsAtOnce) {
            // The policy dropped mid-sequence (backgrounding, VoiceOver turned on): land it.
            if landsAtOnce {
                finish()
            }
        }
    }

    /// Seconds into the sheet at `date`, held at `total` once finished and at 0 before it plays.
    private func sheetTime(at date: Date) -> TimeInterval {
        if isFinished { return sheet.total }
        guard let start else { return 0 }
        return min(sheet.total, max(0, date.timeIntervalSince(start)))
    }

    private func begin(landsAtOnce: Bool) {
        firedCount = 0
        isFinished = false
        if landsAtOnce || sheet.total <= 0 {
            start = nil
            finish()
        } else {
            start = Date()
            if isSkipped {
                skip()
            }
        }
    }

    /// Fires the cues the clock has reached, in order, and ends the sheet at `total`.
    private func advance(to elapsed: TimeInterval) {
        guard start != nil, !isFinished else { return }
        fireCues(upTo: elapsed)
        if elapsed >= sheet.total {
            finish()
        }
    }

    private func fireCues(upTo elapsed: TimeInterval) {
        let cues = sheet.cues
        while firedCount < cues.count, cues[firedCount].start <= elapsed {
            let cue = cues[firedCount]
            firedCount += 1
            onCue?(cue.name)
        }
    }

    /// Jumps the clock so the last `Timing.openingSkip` seconds play from here. The cues passed
    /// over fire on the next frame, in order; a sheet already in its tail is left to land.
    private func skip() {
        guard let current = start, !isFinished else { return }
        let now = Date()
        let tail = max(0, sheet.total - Timing.openingSkip)
        guard now.timeIntervalSince(current) < tail else { return }
        start = now.addingTimeInterval(-tail)
    }

    private func finish() {
        guard !isFinished else { return }
        fireCues(upTo: .infinity)
        isFinished = true
        onFinished?()
    }
}
