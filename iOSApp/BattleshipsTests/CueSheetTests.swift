import Foundation
import Testing
@testable import Battleships

// Foundation only (no UIKit or SwiftUI), so these also run in the Linux compile check.

/// Frames are fractions of a second, so compare them with a little slack.
private func expectClose(
    _ value: Double,
    _ expected: Double,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(abs(value - expected) < 1e-9, comment, sourceLocation: sourceLocation)
}

@Suite("Cue sheet")
struct CueSheetTests {
    /// Out of order on purpose: the sheet sorts by start.
    let sheet = CueSheet([
        Cue(name: "rule", start: 0.8, duration: 0.4),
        Cue(name: "title", start: 0, duration: 0.5),
        Cue(name: "beat", start: 1.0),
        Cue(name: "rows", start: 0.4, duration: 0.3),
    ], total: 1.5)

    @Test func cuesPlayInOrderOfStart() {
        #expect(sheet.cues.map(\.name) == ["title", "rows", "rule", "beat"])
        #expect(sheet.total == 1.5)
        expectClose(sheet.cue("rule")?.end ?? -1, 1.2)
        #expect(sheet.cue("missing") == nil)
    }

    @Test func cuesAtTheSameStartKeepTheirOrder() {
        let sheet = CueSheet([
            Cue(name: "a", start: 0.2, duration: 0.1),
            Cue(name: "b", start: 0.2, duration: 0.1),
            Cue(name: "c", start: 0.2, duration: 0.1),
        ])
        #expect(sheet.cues.map(\.name) == ["a", "b", "c"])
        expectClose(sheet.total, 0.3, "a sheet without a total is as long as its last cue")
        #expect(CueSheet([]).total == 0)
    }

    @Test func progressClampsToTheCue() {
        expectClose(sheet.frame(at: -1, collapsed: false).progress("title", curve: Easing.linear), 0)
        expectClose(sheet.frame(at: 0, collapsed: false).progress("title", curve: Easing.linear), 0)
        expectClose(sheet.frame(at: 0.25, collapsed: false).progress("title", curve: Easing.linear), 0.5)
        expectClose(sheet.frame(at: 0.5, collapsed: false).progress("title", curve: Easing.linear), 1)
        expectClose(sheet.frame(at: 3, collapsed: false).progress("title", curve: Easing.linear), 1)
        #expect(sheet.frame(at: 0.25, collapsed: false).progress("missing") == 0, "an unknown cue never starts")
    }

    @Test func progressGoesThroughTheCurve() {
        let frame = sheet.frame(at: 0.25, collapsed: false)
        expectClose(frame.progress("title"), Easing.easeOut(0.5), "ease-out by default")
        expectClose(frame.progress("title", curve: Easing.linear), 0.5)
        expectClose(Easing.easeOut(0.5), 0.875)
        expectClose(Easing.easeOut(0), 0)
        expectClose(Easing.easeOut(1), 1)
        expectClose(Easing.easeOut(2), 1, "curves clamp their input")
        expectClose(Easing.easeIn(0.5), 0.125)
        expectClose(Easing.easeInOut(0.5), 0.5)
        expectClose(Easing.linear(-1), 0)
    }

    @Test func staggerOffsetsEachIndex() {
        // "rows" runs 0.4…0.7; with a 0.1 s stagger the second row runs 0.5…0.8, the third 0.6…0.9.
        let frame = sheet.frame(at: 0.55, collapsed: false)
        expectClose(frame.progress("rows", index: 0, stagger: 0.1, curve: Easing.linear), 0.5)
        expectClose(frame.progress("rows", index: 1, stagger: 0.1, curve: Easing.linear), 0.05 / 0.3)
        expectClose(frame.progress("rows", index: 2, stagger: 0.1, curve: Easing.linear), 0)
        expectClose(frame.progress("rows", index: -3, stagger: 0.1, curve: Easing.linear), 0.5, "a negative index is the first")
        expectClose(sheet.frame(at: 2, collapsed: false).progress("rows", index: 9, stagger: 0.1), 1)
    }

    @Test func aBeatWithNoDurationIsAStep() {
        #expect(sheet.frame(at: 0.99, collapsed: false).progress("beat") == 0)
        #expect(sheet.frame(at: 1.0, collapsed: false).progress("beat") == 1)
        #expect(!sheet.frame(at: 1.0, collapsed: false).isActive("beat"), "a moment is never active")
        #expect(sheet.frame(at: 1.0, collapsed: false).hasStarted("beat"))
        #expect(sheet.frame(at: 1.0, collapsed: false).hasEnded("beat"))
    }

    @Test func activeStartedAndEnded() {
        let before = sheet.frame(at: 0.7, collapsed: false)
        #expect(!before.isActive("rule"))
        #expect(!before.hasStarted("rule"))
        #expect(!before.hasEnded("rule"))

        let during = sheet.frame(at: 0.9, collapsed: false)
        #expect(during.isActive("rule"))
        #expect(during.hasStarted("rule"))
        #expect(!during.hasEnded("rule"))
        #expect(!during.isFinished)

        // 0.8 + 0.4 lands a hair past 1.2 in binary, so sample clearly after the cue's end.
        let after = sheet.frame(at: 1.25, collapsed: false)
        #expect(!after.isActive("rule"))
        #expect(after.hasEnded("rule"))
        #expect(!after.isFinished)
        expectClose(sheet.cue("rule")?.end ?? -1, 1.2)
        #expect(sheet.frame(at: 1.5, collapsed: false).isFinished)
        #expect(!during.isActive("missing"))
        #expect(!during.hasStarted("missing"))
    }

    @Test func aCollapsedFrameReadsOne() {
        let frame = sheet.frame(at: 0.1, collapsed: true)
        #expect(frame.elapsed == sheet.total, "a collapsed frame sits at the end")
        for name in ["title", "rows", "rule", "beat"] {
            #expect(frame.progress(name) == 1)
            #expect(frame.progress(name, index: 5, stagger: 1) == 1)
            #expect(frame.hasStarted(name))
            #expect(frame.hasEnded(name))
            #expect(!frame.isActive(name))
        }
        #expect(frame.isFinished)
    }

    @Test func elapsedNeverGoesBelowZero() {
        #expect(sheet.frame(at: -5, collapsed: false).elapsed == 0)
        #expect(Cue(name: "x", start: -1, duration: -1).start == 0)
        #expect(Cue(name: "x", start: -1, duration: -1).duration == 0)
    }
}
