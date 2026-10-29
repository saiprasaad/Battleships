import Foundation
import Testing
@testable import Battleships

// Foundation only (no UIKit or SwiftUI), so these also run in the Linux compile check.

/// Effect clocks run on fractions of a second, so compare them with a little slack.
private func expectClose(
    _ value: TimeInterval,
    _ expected: TimeInterval,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(abs(value - expected) < 1e-6, comment, sourceLocation: sourceLocation)
}

@MainActor
@Suite("Effect clock")
struct FXClockTests {
    let origin = Date(timeIntervalSinceReferenceDate: 1_000)

    /// The wall clock `seconds` after the effect clock began.
    private func wall(_ seconds: TimeInterval) -> Date {
        origin.addingTimeInterval(seconds)
    }

    @Test func advancesOneToOneByDefault() {
        let clock = FXClock(start: origin)
        expectClose(clock.time(at: origin), 0)
        expectClose(clock.time(at: wall(0.5)), 0.5)
        expectClose(clock.time(at: wall(3)), 3)
        expectClose(clock.time(at: wall(-1)), 0, "nothing before it began")
        #expect(!clock.isFrozen(at: wall(1)))
    }

    @Test func hitStopHoldsThenResumes() {
        let clock = FXClock(start: origin)
        clock.hitStop(0.07, at: wall(1))
        #expect(clock.isFrozen(at: wall(1)))
        #expect(clock.isFrozen(at: wall(1.05)))
        #expect(!clock.isFrozen(at: wall(1.07)))
        expectClose(clock.time(at: wall(1)), 1)
        expectClose(clock.time(at: wall(1.05)), 1, "stands still through the stop")
        expectClose(clock.time(at: wall(1.07)), 1)
        expectClose(clock.time(at: wall(1.5)), 1.43, "then runs 1:1 again")
    }

    @Test func slowMotionStretchesEffectTime() {
        let clock = FXClock(start: origin)
        clock.slowMotion(scale: 0.35, for: 0.6, at: wall(2))
        expectClose(clock.time(at: wall(2)), 2)
        expectClose(clock.time(at: wall(2.3)), 2 + 0.3 * 0.35)
        expectClose(clock.time(at: wall(2.6)), 2.21, "0.6 s of wall time is 0.21 s of effect time")
        expectClose(clock.time(at: wall(3.6)), 3.21, "back to 1:1 afterwards")
    }

    @Test func hitStopDuringSlowMotionWinsThenSlowMotionResumes() {
        let clock = FXClock(start: origin)
        clock.slowMotion(scale: 0.35, for: 0.6, at: wall(2))
        clock.hitStop(0.1, at: wall(2.2))
        let atStop = clock.time(at: wall(2.2))
        expectClose(atStop, 2.07)
        expectClose(clock.time(at: wall(2.25)), atStop, "the stop wins")
        expectClose(clock.time(at: wall(2.3)), atStop)
        // Slow motion then runs for the 0.4 s it had left, until 2.7 s on the wall clock.
        expectClose(clock.time(at: wall(2.5)), atStop + 0.2 * 0.35)
        expectClose(clock.time(at: wall(2.7)), 2.21)
        expectClose(clock.time(at: wall(3.7)), 3.21)
    }

    @Test func hitStopAndSlowMotionAtTheSameMoment() {
        // The finale: a long stop on the last landing, then slow motion.
        let clock = FXClock(start: origin)
        clock.hitStop(0.14, at: wall(5))
        clock.slowMotion(scale: 0.35, for: 0.6, at: wall(5))
        expectClose(clock.time(at: wall(5.1)), 5)
        expectClose(clock.time(at: wall(5.14)), 5)
        expectClose(clock.time(at: wall(5.74)), 5.21)
        expectClose(clock.time(at: wall(6)), 5.47)

        // The same in the other order.
        let reversed = FXClock(start: origin)
        reversed.slowMotion(scale: 0.35, for: 0.6, at: wall(5))
        reversed.hitStop(0.14, at: wall(5))
        expectClose(reversed.time(at: wall(5.74)), 5.21)
        expectClose(reversed.time(at: wall(6)), 5.47)
    }

    @Test func overlappingHitStopsMergeIntoOne() {
        let clock = FXClock(start: origin)
        clock.hitStop(0.1, at: wall(1))
        clock.hitStop(0.1, at: wall(1.05))
        #expect(clock.isFrozen(at: wall(1.12)))
        #expect(!clock.isFrozen(at: wall(1.15)))
        expectClose(clock.time(at: wall(1.15)), 1)
        expectClose(clock.time(at: wall(2)), 1.85)
    }

    @Test func aNewerSlowMotionOverridesWhereTheyOverlap() {
        let clock = FXClock(start: origin)
        clock.slowMotion(scale: 0.5, for: 1, at: wall(1))
        clock.slowMotion(scale: 0.1, for: 0.2, at: wall(1.5))
        expectClose(clock.time(at: wall(1.5)), 1.25)
        expectClose(clock.time(at: wall(1.7)), 1.27, "the newer, slower stretch wins")
        expectClose(clock.time(at: wall(2)), 1.42, "the older stretch finishes afterwards")
        expectClose(clock.time(at: wall(3)), 2.42)
    }

    @Test func neverRunsBackwards() {
        let clock = FXClock(start: origin)
        clock.slowMotion(scale: 0.35, for: 0.6, at: wall(1))
        clock.hitStop(0.07, at: wall(1.2))
        clock.slowMotion(scale: 0.5, for: 0.2, at: wall(1.4))
        clock.hitStop(0.09, at: wall(1.45))
        var last = clock.time(at: origin)
        for step in 0...400 {
            let now = clock.time(at: wall(Double(step) * 0.01))
            #expect(now >= last)
            last = now
        }
    }

    @Test func ignoresEmptyStopsAndStretches() {
        let clock = FXClock(start: origin)
        clock.hitStop(0, at: wall(1))
        clock.slowMotion(scale: 0.35, for: 0, at: wall(1))
        expectClose(clock.time(at: wall(2)), 2)
        #expect(!clock.isFrozen(at: wall(1)))
    }
}

@MainActor
@Suite("Cue sheet")
struct CueSheetTests {
    /// What a sheet did, in order.
    @MainActor
    final class Log {
        var entries: [String] = []
        var finished = false
    }

    private struct TimedOut: Error {}

    /// Lets the sheet's task run until `condition` holds, failing after about a second.
    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw TimedOut()
    }

    @Test func cuesFireInOrderThenFinish() async throws {
        let log = Log()
        let sheet = CueSheet([
            CueSheet.Cue(at: 0.05) { log.entries.append("second") },
            CueSheet.Cue(at: 0) { log.entries.append("first") },
            CueSheet.Cue(at: 0.1) { log.entries.append("third") },
        ], onFinish: { log.finished = true })
        #expect(!sheet.isPlaying)
        sheet.play()
        #expect(sheet.isPlaying)
        sheet.play()   // a second play while playing changes nothing
        try await waitUntil { log.finished }
        #expect(log.entries == ["first", "second", "third"])
        #expect(!sheet.isPlaying)
    }

    @Test func cuesAtTheSameOffsetKeepTheirOrder() async throws {
        let log = Log()
        let sheet = CueSheet([
            CueSheet.Cue(at: 0.02) { log.entries.append("a") },
            CueSheet.Cue(at: 0.02) { log.entries.append("b") },
            CueSheet.Cue(at: 0.02) { log.entries.append("c") },
        ], onFinish: { log.finished = true })
        sheet.play()
        try await waitUntil { log.finished }
        #expect(log.entries == ["a", "b", "c"])
    }

    @Test func skipRunsTheRestAtOnce() async throws {
        let log = Log()
        let sheet = CueSheet([
            CueSheet.Cue(at: 0) { log.entries.append("a") },
            CueSheet.Cue(at: 10) { log.entries.append("b") },
            CueSheet.Cue(at: 20) { log.entries.append("c") },
        ], onFinish: { log.finished = true })
        sheet.play()
        try await waitUntil { log.entries.count == 1 }
        #expect(!log.finished)
        sheet.skip()
        #expect(log.entries == ["a", "b", "c"], "the rest runs immediately, in order")
        #expect(log.finished)
        #expect(!sheet.isPlaying)
        // Nothing runs twice afterwards.
        try await Task.sleep(for: .milliseconds(50))
        #expect(log.entries.count == 3)
        sheet.skip()
        #expect(log.entries.count == 3, "skipping a finished sheet does nothing")
    }

    @Test func cancelRunsNothingMore() async throws {
        let log = Log()
        let sheet = CueSheet([
            CueSheet.Cue(at: 0) { log.entries.append("a") },
            CueSheet.Cue(at: 0.03) { log.entries.append("b") },
        ], onFinish: { log.finished = true })
        sheet.play()
        try await waitUntil { log.entries.count == 1 }
        sheet.cancel()
        #expect(!sheet.isPlaying)
        try await Task.sleep(for: .milliseconds(80))
        #expect(log.entries == ["a"])
        #expect(!log.finished, "a cancelled sheet never finishes")
    }

    @Test func playsAgainAfterFinishing() async throws {
        let log = Log()
        let sheet = CueSheet([CueSheet.Cue(at: 0) { log.entries.append("a") }], onFinish: { log.finished = true })
        sheet.play()
        try await waitUntil { log.finished }
        log.finished = false
        sheet.play()
        try await waitUntil { log.finished }
        #expect(log.entries == ["a", "a"])
    }

    @Test func anEmptySheetJustFinishes() async throws {
        let log = Log()
        let sheet = CueSheet([], onFinish: { log.finished = true })
        sheet.play()
        try await waitUntil { log.finished }
        #expect(!sheet.isPlaying)
    }
}

@MainActor
@Suite("Effects settings")
struct EffectsSettingsTests {
    @Test func everythingIsOnUntilTurnedDown() throws {
        let defaults = try #require(UserDefaults(suiteName: "EffectsTest-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        #expect(settings.effectsLevel == .full)
        #expect(settings.screenShakeEnabled)
        #expect(settings.flashesEnabled)
        #expect(settings.hapticStrength == 1)
        #expect(settings.ambientSoundEnabled)
    }

    @Test func remembersTheEffectsChoices() throws {
        let defaults = try #require(UserDefaults(suiteName: "EffectsTest-\(UUID().uuidString)"))
        let settings = AppSettings(defaults: defaults)
        settings.effectsLevel = .reduced
        settings.screenShakeEnabled = false
        settings.flashesEnabled = false
        settings.hapticStrength = 0.5
        settings.ambientSoundEnabled = false

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.effectsLevel == .reduced)
        #expect(!reloaded.screenShakeEnabled)
        #expect(!reloaded.flashesEnabled)
        #expect(reloaded.hapticStrength == 0.5)
        #expect(!reloaded.ambientSoundEnabled)
    }

    @Test func fallsBackFromAnUnknownLevel() throws {
        let defaults = try #require(UserDefaults(suiteName: "EffectsTest-\(UUID().uuidString)"))
        defaults.set("cinematic", forKey: "effectsLevel")
        defaults.set(7.0, forKey: "hapticStrength")
        let settings = AppSettings(defaults: defaults)
        #expect(settings.effectsLevel == .full)
        #expect(settings.hapticStrength == 1, "strength is clamped to 0…1")
    }

    @Test func levelsHaveNamesForThePicker() {
        #expect(EffectsLevel.allCases.map(\.displayName) == ["Full", "Reduced", "Minimal"])
        #expect(EffectsLevel.allCases.map(\.id) == ["full", "reduced", "minimal"])
    }
}

@Suite("Pacing budget")
struct TimingTests {
    @Test func tokensKeepTheBudgets() {
        #expect(Timing.shellFlight == 0.42)
        #expect(Timing.apexHold < Timing.shellFlight)
        #expect(Timing.secondaryStep >= 0.12, "chain detonations never strobe")
        #expect(Timing.finaleCard + 0.35 <= 3.0, "the card is up within 3 s of the last landing")
        #expect(Timing.opening <= 1.5)
        #expect(Timing.finaleCardReduced < Timing.finaleCard)
        #expect(Timing.Stagger.row * Double(Timing.Stagger.maxItems) < 0.5, "a list settles in under half a second")
    }
}

#if canImport(SwiftUI)
// MotionPolicy lives with the SwiftUI views, so it is only here on Apple platforms. Its resolution
// is pure, which is why it is tested without rendering anything.
@Suite("Motion policy")
struct MotionPolicyTests {
    private func resolve(
        reduceMotion: Bool = false,
        lowPower: Bool = false,
        dimsFlashingLights: Bool = false,
        thermalState: ProcessInfo.ThermalState = .nominal,
        voiceOver: Bool = false,
        effects: EffectsLevel = .full,
        screenShake: Bool = true,
        flashes: Bool = true,
        hapticStrength: Double = 1
    ) -> MotionPolicy {
        MotionPolicy.resolve(
            reduceMotion: reduceMotion,
            lowPower: lowPower,
            dimsFlashingLights: dimsFlashingLights,
            thermalState: thermalState,
            voiceOver: voiceOver,
            effects: effects,
            screenShake: screenShake,
            flashes: flashes,
            hapticStrength: hapticStrength
        )
    }

    @Test func everythingOnIsTheFullTier() {
        #expect(resolve() == .full)
        #expect(!resolve().loopsHoldStill)
    }

    @Test func reduceMotionVoiceOverAndMinimalHoldStill() {
        for policy in [resolve(reduceMotion: true), resolve(voiceOver: true), resolve(effects: .minimal)] {
            #expect(policy.tier == .still)
            #expect(policy.loopsHoldStill)
            #expect(!policy.allowsFlashes)
            #expect(!policy.allowsShake)
        }
        #expect(resolve(voiceOver: true).isVoiceOverRunning)
        #expect(resolve(reduceMotion: true, lowPower: true).tier == .still, "still beats reduced")
    }

    @Test func lowPowerHeatAndReducedEffectsDropATier() {
        for policy in [
            resolve(lowPower: true),
            resolve(thermalState: .serious),
            resolve(thermalState: .critical),
            resolve(effects: .reduced),
        ] {
            #expect(policy.tier == .reduced)
            #expect(!policy.loopsHoldStill)
            #expect(!policy.allowsFlashes)
            #expect(!policy.allowsShake)
            #expect(policy.ambientFrameInterval == 1 / 20)
        }
        #expect(resolve(thermalState: .fair).tier == .full)
        #expect(resolve().ambientFrameInterval == 1 / 30)
    }

    @Test func flashesAndShakeAreTheirOwnSwitches() {
        #expect(!resolve(flashes: false).allowsFlashes)
        #expect(resolve(flashes: false).allowsShake)
        #expect(!resolve(dimsFlashingLights: true).allowsFlashes)
        #expect(resolve(dimsFlashingLights: true).tier == .full, "Dim Flashing Lights only takes the flashes")
        #expect(!resolve(screenShake: false).allowsShake)
        #expect(resolve(screenShake: false).allowsFlashes)
    }

    @Test func hapticStrengthIsClamped() {
        #expect(resolve(hapticStrength: 0.5).hapticStrength == 0.5)
        #expect(resolve(hapticStrength: 2).hapticStrength == 1)
        #expect(resolve(hapticStrength: -1).hapticStrength == 0)
    }

    @Test func tiersCompareFromStillToFull() {
        #expect(MotionPolicy.Tier.still < .reduced)
        #expect(MotionPolicy.Tier.reduced < .full)
        #expect(MotionPolicy.reduced.tier < MotionPolicy.full.tier)
        #expect(MotionPolicy.still.tier < MotionPolicy.reduced.tier)
    }
}
#endif
