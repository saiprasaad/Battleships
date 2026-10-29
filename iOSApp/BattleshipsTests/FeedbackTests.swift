import Foundation
import Testing
@testable import Battleships

@Suite("Haptic score")
struct HapticScoreTests {
    /// Events that deliberately have no haptic. None today: every cue has a tactile twin.
    static let silent: Set<FeedbackEvent> = []

    @Test(arguments: FeedbackEvent.allCases)
    func everyEventHasAScoreOrIsDeliberatelySilent(event: FeedbackEvent) {
        #expect((HapticScore.score(for: event) != nil) == !Self.silent.contains(event))
    }

    @Test(arguments: FeedbackEvent.allCases)
    func scoresAreWellFormed(event: FeedbackEvent) {
        guard let score = HapticScore.score(for: event) else { return }
        #expect(!score.events.isEmpty)
        for cue in score.events {
            #expect((0...1).contains(cue.intensity))
            #expect((0...1).contains(cue.sharpness))
            #expect(cue.time >= 0)
            #expect(cue.duration >= 0)
            if cue.kind == .transient {
                #expect(cue.duration == 0)
            }
        }
        let times = score.events.map(\.time)
        #expect(times == times.sorted(), "cues are in playing order")
        #expect(score.duration == score.events.map { $0.time + $0.duration }.max())
        #expect(score.duration <= 3, "no haptic outlives its moment")
    }

    @Test func scalingKeepsIntensitiesInRange() throws {
        let hit = try #require(HapticScore.score(for: .hit))
        #expect(hit.scaled(by: 2).events.allSatisfy { $0.intensity <= 1 })
        #expect(hit.scaled(by: 2).events.contains { $0.intensity == 1 })
        #expect(hit.scaled(by: 0).events.allSatisfy { $0.intensity == 0 })
        #expect(hit.scaled(by: -1).events.allSatisfy { $0.intensity == 0 })
        let half = hit.scaled(by: 0.5)
        #expect(half.events.count == hit.events.count)
        for (cue, original) in zip(half.events, hit.events) {
            #expect(abs(cue.intensity - original.intensity * 0.5) < 1e-9)
            #expect(cue.sharpness == original.sharpness)
            #expect(cue.time == original.time)
            #expect(cue.duration == original.duration)
            #expect(cue.kind == original.kind)
        }
    }

    @Test func sunkChainsItsDetonationsNoFasterThanTheScreen() throws {
        let sunk = try #require(HapticScore.score(for: .sunk))
        let transients = sunk.events.filter { $0.kind == .transient }.map(\.time)
        #expect(transients.count >= 4, "the hit and three secondaries")
        for (earlier, later) in zip(transients, transients.dropFirst()) {
            #expect(later - earlier + 1e-9 >= Timing.secondaryStep)
        }
        #expect(sunk.events.contains { $0.kind == .continuous && $0.duration >= 0.4 }, "a long, low rumble")
    }

    @Test func finalBlowIsTheHitInSlowMotion() throws {
        let hit = try #require(HapticScore.score(for: .hit))
        let finalBlow = try #require(HapticScore.score(for: .finalBlow))
        #expect(finalBlow.events.count == hit.events.count)
        #expect(abs(finalBlow.duration - hit.duration / Timing.finalTimeScale) < 1e-6)
        #expect(finalBlow.events.map(\.intensity) == hit.events.map(\.intensity))
    }

    @Test func whistleRisesForTheTelegraph() throws {
        let whistle = try #require(HapticScore.score(for: .whistle))
        #expect(abs(whistle.duration - Timing.whistle) < 1e-6)
        #expect(whistle.events.allSatisfy { $0.kind == .continuous })
        let sharpness = whistle.events.map(\.sharpness)
        #expect(sharpness == sharpness.sorted() && sharpness.first != sharpness.last, "rising")
    }

    @Test func fireIsRecoilThenATail() throws {
        let fire = try #require(HapticScore.score(for: .fire))
        let recoil = try #require(fire.events.first)
        #expect(recoil.kind == .transient && recoil.intensity == 0.9 && recoil.sharpness == 0.8)
        #expect(fire.events.contains { $0.kind == .continuous && abs($0.duration - 0.05) < 1e-9 })
    }

    @Test func tickAndSelectStayLight() throws {
        let tick = try #require(HapticScore.score(for: .tick))
        #expect(tick.events.count == 1)
        #expect(tick.events.first?.kind == .transient)
        #expect(tick.events.first?.intensity == 0.15)
        let select = try #require(HapticScore.score(for: .select))
        #expect(select.events.count == 1)
        #expect(select.events.first?.kind == .transient)
        #expect(select.events.first.map { $0.intensity <= 0.5 } == true)
    }
}

@Suite("Sound stage")
struct SoundStageTests {
    static let varied: Set<FeedbackEvent> = [.fire, .hit, .miss, .sunk, .incoming]

    @Test(arguments: FeedbackEvent.allCases)
    func everyEventHasWellFormedTakes(event: FeedbackEvent) {
        let takes = SoundSynthesis.variants(for: event)
        #expect(takes.count == (Self.varied.contains(event) ? 3 : 1))
        for take in takes {
            #expect(!take.isEmpty)
            #expect(take.allSatisfy { $0.isFinite && abs($0) <= 1 })
            #expect(take.contains { abs($0) > 0.05 })
        }
    }

    @Test func shellsLandAtOnce() {
        for event in [FeedbackEvent.hit, .miss, .sunk] {
            for take in SoundSynthesis.variants(for: event) {
                #expect(take.prefix(1_000).contains { $0 != 0 }, "\(event) no longer starts with flight silence")
            }
        }
    }

    @Test func pitchVariantsAreResampled() {
        let takes = SoundSynthesis.variants(for: .fire)
        #expect(takes[1].count > takes[0].count, "4 % lower is 4 % longer")
        #expect(takes[2].count < takes[0].count, "4 % higher is 4 % shorter")
        let stretch = Double(takes[1].count) / Double(takes[0].count)
        let expected = 1 / 0.96
        #expect(abs(stretch - expected) < 0.001)
    }

    @Test func allVariantsCoverEveryEvent() {
        let all = SoundSynthesis.allVariants()
        #expect(all.count == FeedbackEvent.allCases.count)
        #expect(all.values.allSatisfy { !$0.isEmpty })
    }

    @Test func tickIsFarDown() {
        let peak = SoundSynthesis.samples(for: .tick).reduce(0) { max($0, abs($1)) }
        #expect(peak > 0.05 && peak < 0.07, "about −24 dB")
        #expect(SoundSynthesis.samples(for: .tick).count <= SoundSynthesis.frames(0.015))
    }

    @Test func whistleLastsTheTelegraph() {
        #expect(SoundSynthesis.samples(for: .whistle).count == SoundSynthesis.frames(Timing.whistle))
    }

    @Test func finalBlowIsStretched() {
        let slow = SoundSynthesis.samples(for: .finalBlow)
        #expect(slow.count > SoundSynthesis.frames(1.1 / Timing.finalTimeScale) - 2)
        #expect(slow.count <= SoundSynthesis.frames(1.1 / Timing.finalTimeScale) + 2)
    }

    @Test func ambientBedLoopsQuietly() {
        let bed = SoundSynthesis.ambientBed()
        #expect(bed.count == SoundSynthesis.frames(8))
        let peak = bed.reduce(0) { max($0, abs($1)) }
        #expect(peak <= 0.25 + 1e-4 && peak > 0.2)
        #expect(bed.allSatisfy { $0.isFinite })
        #expect(bed.prefix(2_000).allSatisfy { abs($0) <= 0.1 }, "quiet into the seam")
        #expect(bed.suffix(2_000).allSatisfy { abs($0) <= 0.1 }, "quiet out of the seam")
        let middle = bed[(bed.count / 2 - 20_000)..<(bed.count / 2 + 20_000)]
        #expect(middle.contains { abs($0) > 0.1 }, "the middle is not quiet")
    }

    @Test func aShorterBedIsStillALoop() {
        let bed = SoundSynthesis.ambientBed(seconds: 3)
        #expect(bed.count == SoundSynthesis.frames(3))
        #expect(bed.prefix(2_000).allSatisfy { abs($0) <= 0.1 })
        #expect(bed.suffix(2_000).allSatisfy { abs($0) <= 0.1 })
    }
}

/// Records what a player is asked for, ambience included.
@MainActor
private final class StageRecorder: FeedbackPlayer {
    var events: [FeedbackEvent] = []
    var ambience: [Bool] = []

    func play(_ event: FeedbackEvent) {
        events.append(event)
    }

    func setAmbience(_ isOn: Bool) {
        ambience.append(isOn)
    }
}

/// A player with no ambient bed: it relies on the protocol's default.
@MainActor
private final class Rumble: FeedbackPlayer {
    var events: [FeedbackEvent] = []

    func play(_ event: FeedbackEvent) {
        events.append(event)
    }
}

@MainActor
@Suite("Feedback players")
struct FeedbackPlayerTests {
    @Test func combinedFeedbackForwardsEventsAndAmbience() {
        let stage = StageRecorder()
        let rumble = Rumble()
        let combined = CombinedFeedback([rumble, stage])
        combined.play(.hit)
        combined.setAmbience(true)
        combined.play(.whistle)
        combined.setAmbience(false)
        #expect(stage.events == [.hit, .whistle])
        #expect(rumble.events == [.hit, .whistle])
        #expect(stage.ambience == [true, false])
    }

    @Test func ambienceIsOptionalForAPlayer() {
        let rumble = Rumble()
        rumble.setAmbience(true)
        #expect(rumble.events.isEmpty)
    }
}
