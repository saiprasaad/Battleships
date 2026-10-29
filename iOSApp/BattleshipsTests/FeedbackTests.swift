import Foundation
import Testing
@testable import Battleships

@Suite("Haptic score")
struct HapticScoreTests {
    /// The landing patterns: every one starts with a transient at 0, the frame of impact.
    static let landings: [FeedbackEvent] = [.miss, .nearMiss, .hit, .hitOwn, .sunk, .sunkOwn, .finalBlow]

    @Test(arguments: FeedbackEvent.allCases)
    func everyEventHasAScoreOrIsSilentListed(event: FeedbackEvent) {
        #expect((HapticScore.score(for: event) != nil) == !HapticScore.silentEvents.contains(event))
        #expect(HapticScore.silentEvents == [.burning], "loops are sound only")
    }

    @Test(arguments: FeedbackEvent.allCases)
    func scoresAreWellFormed(event: FeedbackEvent) {
        guard let score = HapticScore.score(for: event) else { return }
        for candidate in [score, score.rendered()] {
            #expect(!candidate.events.isEmpty)
            for cue in candidate.events {
                #expect((0...1).contains(cue.intensity))
                #expect((0...1).contains(cue.sharpness))
                #expect(cue.intensityCurve.allSatisfy { (0...1).contains($0.value) && $0.time >= 0 && $0.time <= cue.duration + 1e-9 })
                #expect(cue.sharpnessCurve.allSatisfy { (0...1).contains($0.value) && $0.time >= 0 && $0.time <= cue.duration + 1e-9 })
                #expect(cue.time >= 0)
                #expect(cue.duration >= 0)
                if cue.kind == .transient {
                    #expect(cue.duration == 0)
                    #expect(cue.intensityCurve.isEmpty && cue.sharpnessCurve.isEmpty)
                }
            }
            let times = candidate.events.map(\.time)
            #expect(times == times.sorted(), "cues are in playing order")
            #expect(candidate.duration == candidate.events.map { $0.time + $0.duration }.max())
            #expect(candidate.duration <= 3, "no haptic outlives its moment")
        }
        #expect(abs(score.rendered().duration - score.duration) < 1e-9, "rendering keeps the length")
    }

    @Test func fireRumbleLastsTheFlight() throws {
        let fire = try #require(HapticScore.score(for: .fire))
        let kick = try #require(fire.events.first)
        #expect(kick.kind == .transient && kick.time == 0 && kick.intensity == 1 && kick.sharpness == 0.8)
        let rumbles = fire.events.filter { $0.kind == .continuous }
        #expect(rumbles.count == 1)
        let rumble = try #require(rumbles.first)
        #expect(rumble.time == 0)
        #expect(abs(rumble.duration - Timing.shellFlight) < 1e-9, "the rumble ends exactly as the landing starts")
        #expect(rumble.intensity(at: 0) < rumble.intensity(at: rumble.duration), "it builds")
        #expect(rumble.sharpness(at: 0) < rumble.sharpness(at: rumble.duration))
        #expect(abs(rumble.intensity(at: rumble.duration / 2) - (0.15 + 0.55) / 2) < 1e-9, "linear in between")
        #expect(abs(fire.duration - Timing.shellFlight) < 1e-9)

        // Rendered for an engine without curves: flat steps covering the flight, rising all the way.
        let steps = fire.rendered().events.filter { $0.kind == .continuous }
        #expect(steps.count >= 10)
        #expect(steps.first?.time == 0)
        for (earlier, later) in zip(steps, steps.dropFirst()) {
            #expect(abs(earlier.time + earlier.duration - later.time) < 1e-9, "contiguous")
            #expect(earlier.intensity <= later.intensity)
            #expect(earlier.sharpness <= later.sharpness)
        }
        let end = try #require(steps.last)
        #expect(abs(end.time + end.duration - Timing.shellFlight) < 1e-9)
    }

    @Test(arguments: HapticScoreTests.landings)
    func landingsStartAtZero(event: FeedbackEvent) throws {
        let variations: [FeedbackVariation] = [
            .default,
            FeedbackVariation(isMine: false),
            FeedbackVariation(isFinal: true),
            FeedbackVariation(pan: -0.6, seed: 3, isMine: false, isFinal: true, delay: Timing.shellFlight),
        ]
        for variation in variations {
            let score = try #require(HapticScore.score(for: event, variation: variation))
            let first = try #require(score.events.first)
            #expect(first.kind == .transient && first.time == 0, "\(event) opens with its impact")
            #expect(first.intensity >= 0.5)
        }
    }

    @Test func variationsPickTheFamily() throws {
        #expect(HapticScore.score(for: .hit, variation: FeedbackVariation(isMine: false)) == HapticScore.score(for: .hitOwn))
        #expect(HapticScore.score(for: .sunk, variation: FeedbackVariation(isMine: false)) == HapticScore.score(for: .sunkOwn))
        #expect(HapticScore.score(for: .hit) != HapticScore.score(for: .hitOwn))
        let hit = try #require(HapticScore.score(for: .hit))
        let hitOwn = try #require(HapticScore.score(for: .hitOwn))
        #expect(hitOwn.duration > hit.duration, "theirs on you is longer")
        #expect((hitOwn.events.first?.sharpness ?? 1) < (hit.events.first?.sharpness ?? 0), "and duller")

        let finale = try #require(HapticScore.score(for: .finalBlow))
        #expect(HapticScore.score(for: .sunk, variation: FeedbackVariation(isFinal: true)) == finale)
        #expect(HapticScore.score(for: .sunkOwn, variation: FeedbackVariation(isMine: false, isFinal: true)) == finale)
        #expect(HapticScore.score(for: .hit, variation: FeedbackVariation(isFinal: true)) == finale)
        #expect(finale.events.filter { $0.kind == .transient }.count == 4, "the crack and three echoes")
        #expect(finale.duration > 1.3 && finale.duration <= 1.5)

        let theirs = try #require(HapticScore.score(for: .lastShip, variation: FeedbackVariation(isMine: false)))
        let mine = try #require(HapticScore.score(for: .lastShip, variation: FeedbackVariation(isMine: true)))
        #expect(theirs != mine)
        #expect(theirs.events.count == 2 && mine.events.count == 2)
        #expect(theirs.events[0].intensity < theirs.events[1].intensity, "theirs goes up")
        #expect(mine.events[0].intensity > mine.events[1].intensity, "yours goes down")
        #expect(HapticScore.score(for: .lastShip) == mine, "the default variation is yours")
    }

    @Test func countRepeatsTheTaps() throws {
        let five = try #require(HapticScore.score(for: .shuffle, variation: FeedbackVariation(count: 5)))
        #expect(five.events.count == 5)
        #expect(five.events.allSatisfy { $0.kind == .transient })
        for (index, tap) in five.events.enumerated() {
            #expect(abs(tap.time - Double(index) * Timing.Stagger.ship) < 1e-9)
        }
        #expect(HapticScore.score(for: .shuffle, variation: FeedbackVariation(count: 0))?.events.count == 1)
        #expect(HapticScore.score(for: .shuffle, variation: FeedbackVariation(count: 40))?.events.count == Timing.Stagger.maxItems)

        #expect(HapticScore.score(for: .streak)?.events.count == 3)
        #expect(HapticScore.score(for: .streak, variation: FeedbackVariation(count: 5))?.events.count == 4)
        #expect(HapticScore.score(for: .streak, variation: FeedbackVariation(count: 11))?.events.count == 5, "never more than five")
    }

    @Test func intensityScalesAndCaps() throws {
        let hit = try #require(HapticScore.score(for: .hit))
        let half = try #require(HapticScore.score(for: .hit, variation: FeedbackVariation(intensity: 0.5)))
        #expect(half.events.count == hit.events.count)
        for (cue, original) in zip(half.events, hit.events) {
            #expect(abs(cue.intensity - original.intensity * 0.5) < 1e-9)
            #expect(cue.sharpness == original.sharpness)
            #expect(cue.time == original.time && cue.duration == original.duration && cue.kind == original.kind)
            for (point, source) in zip(cue.intensityCurve, original.intensityCurve) {
                #expect(abs(point.value - source.value * 0.5) < 1e-9 && point.time == source.time)
            }
            #expect(cue.sharpnessCurve == original.sharpnessCurve)
        }
        let loud = try #require(HapticScore.score(for: .hit, variation: FeedbackVariation(intensity: 3)))
        #expect(loud.events.allSatisfy { $0.intensity <= 1 && $0.intensityCurve.allSatisfy { $0.value <= 1 } })
        #expect(loud.events.contains { $0.intensity == 1 })
        #expect(hit.scaled(by: 0).events.allSatisfy { $0.intensity == 0 })
        #expect(hit.scaled(by: -1).events.allSatisfy { $0.intensity == 0 })
    }

    @Test func reduceMotionCapsAndShortens() throws {
        for event in FeedbackEvent.allCases {
            guard let score = HapticScore.score(for: event) else { continue }
            let capped = score.reduceMotionCapped()
            #expect(capped.events.count == score.events.count)
            for (cue, original) in zip(capped.events, score.events) {
                #expect(cue.intensity <= 0.7 + 1e-9)
                #expect(cue.intensityCurve.allSatisfy { $0.value <= 0.7 + 1e-9 })
                #expect(cue.time == original.time, "taps keep their frame")
                if cue.kind == .continuous {
                    #expect(abs(cue.duration - original.duration * 0.6) < 1e-9)
                    for (point, source) in zip(cue.intensityCurve, original.intensityCurve) {
                        #expect(abs(point.time - source.time * 0.6) < 1e-9)
                    }
                } else {
                    #expect(cue.duration == 0)
                }
            }
        }
        let whistle = try #require(HapticScore.score(for: .whistle)).reduceMotionCapped(maxIntensity: 0.35)
        #expect(whistle.events.allSatisfy { $0.intensity <= 0.35 && $0.intensityCurve.allSatisfy { $0.value <= 0.35 } })
    }

    @Test func whistleRisesForTheTelegraph() throws {
        let whistle = try #require(HapticScore.score(for: .whistle))
        #expect(abs(whistle.duration - Timing.whistle) < 1e-6)
        #expect(whistle.events.allSatisfy { $0.kind == .continuous })
        let rendered = whistle.rendered()
        #expect(abs(rendered.duration - Timing.whistle) < 1e-6)
        let sharpness = rendered.events.map(\.sharpness)
        let intensity = rendered.events.map(\.intensity)
        #expect(sharpness == sharpness.sorted() && sharpness.first != sharpness.last, "rising")
        #expect(intensity == intensity.sorted() && intensity.first != intensity.last)
    }

    @Test func flatScoresRenderToThemselves() throws {
        let miss = try #require(HapticScore.score(for: .miss))
        #expect(miss.rendered() == miss)
        let select = try #require(HapticScore.score(for: .select))
        #expect(select.rendered() == select)
    }

    @Test func sunkChainsItsDetonationsNoFasterThanTheScreen() throws {
        let sunk = try #require(HapticScore.score(for: .sunk))
        let transients = sunk.events.filter { $0.kind == .transient }.map(\.time)
        #expect(transients.count >= 4, "the hit and three secondaries")
        for (earlier, later) in zip(transients, transients.dropFirst()) {
            #expect(later - earlier + 1e-9 >= Timing.secondaryStep)
        }
        #expect(sunk.events.contains { $0.kind == .continuous && $0.duration >= 1 }, "a long, falling rumble")
        let sunkOwn = try #require(HapticScore.score(for: .sunkOwn))
        #expect(sunkOwn.events.count == sunk.events.count + 1, "plus the groan")
        #expect(sunkOwn.duration > sunk.duration)
    }

    @Test func stretchingSlowsEverything() throws {
        let hit = try #require(HapticScore.score(for: .hit))
        let slow = hit.stretched(by: 2)
        #expect(abs(slow.duration - hit.duration * 2) < 1e-9)
        for (cue, original) in zip(slow.events, hit.events) {
            #expect(abs(cue.time - original.time * 2) < 1e-9)
            #expect(abs(cue.duration - original.duration * 2) < 1e-9)
            #expect(cue.intensity == original.intensity)
            for (point, source) in zip(cue.intensityCurve, original.intensityCurve) {
                #expect(abs(point.time - source.time * 2) < 1e-9 && point.value == source.value)
            }
        }
    }

    @Test func melodicCuesTapOnTheirNotes() throws {
        for (event, starts) in SoundSynthesis.noteStarts {
            let score = try #require(HapticScore.score(for: event, variation: FeedbackVariation(isMine: false)))
            let taps = score.events.filter { $0.kind == .transient }.map(\.time)
            for start in starts {
                #expect(taps.contains { abs($0 - start) < 1e-9 }, "\(event) taps at \(start)")
            }
        }
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
        let navigate = try #require(HapticScore.score(for: .navigate))
        #expect(navigate.events.count == 1 && navigate.events.first.map { $0.intensity <= 0.3 } == true)
    }
}

@Suite("Sound stage")
struct SoundStageTests {
    static let landings: [FeedbackEvent] = [.miss, .nearMiss, .hit, .hitOwn, .sunk, .sunkOwn, .finalBlow]

    @Test(arguments: FeedbackEvent.allCases)
    func everyEventHasWellFormedTakes(event: FeedbackEvent) {
        let takes = SoundSynthesis.variants(for: event)
        #expect(takes.count == SoundSynthesis.variantCount(for: event))
        for take in takes {
            #expect(!take.isEmpty)
            #expect(take.allSatisfy { $0.isFinite && abs($0) <= 1 })
            #expect(take.contains { abs($0) > 0.05 })
        }
    }

    @Test func variantCountsFollowTheTable() {
        for event in FeedbackEvent.allCases {
            let expected: Int
            switch event {
            case .fire, .hit, .miss, .sunk: expected = 3
            case .hitOwn, .sunkOwn, .firework, .lastShip: expected = 2
            default: expected = 1
            }
            #expect(SoundSynthesis.variantCount(for: event) == expected, "\(event)")
        }
    }

    @Test func everyVariantDiffers() {
        for event in FeedbackEvent.allCases where SoundSynthesis.variantCount(for: event) > 1 {
            let takes = SoundSynthesis.variants(for: event)
            for first in takes.indices {
                for second in takes.indices where second > first {
                    let length = min(takes[first].count, takes[second].count)
                    var different = 0
                    for index in 0..<length where abs(takes[first][index] - takes[second][index]) > 1e-4 {
                        different += 1
                    }
                    #expect(Double(different) / Double(length) >= 0.01, "\(event) takes \(first) and \(second) are not the same sound")
                }
            }
        }
    }

    @Test(arguments: SoundStageTests.landings)
    func everyLandingSoundStartsAtOnce(event: FeedbackEvent) {
        let onset = SoundSynthesis.frames(0.02)
        for take in SoundSynthesis.variants(for: event) {
            #expect(take.prefix(onset).contains { abs($0) > 0.05 }, "\(event) carries no flight silence")
        }
        if let slow = SoundSynthesis.slowSamples(for: event) {
            #expect(slow.prefix(onset * 3).contains { abs($0) > 0.05 }, "the slow \(event) starts at once too")
        }
    }

    @Test func slowVariantsAreLongerAndLower() throws {
        for event in FeedbackEvent.allCases {
            let slow = SoundSynthesis.slowSamples(for: event)
            #expect((slow != nil) == SoundSynthesis.slowEvents.contains(event), "\(event)")
            guard let slow else { continue }
            let base = SoundSynthesis.samples(for: event)
            #expect(slow.count > base.count, "\(event) slow is longer")
            #expect(slow.count >= SoundSynthesis.frames(2.9) && slow.count <= SoundSynthesis.frames(3.6), "about 3.2 s")
            // The pure explosions drop well below their base; the sunkOwn mix keeps the groan's
            // grit in its quiet tail, so for it "lower" is enough from this crude measure of pitch.
            let bar = event == .sunkOwn ? 0.95 : 0.7
            #expect(Self.crossingsPerSecond(slow) < Self.crossingsPerSecond(base) * bar, "\(event) slow is lower")
            #expect(slow.allSatisfy { $0.isFinite && abs($0) <= 1 })
        }
    }

    static func crossingsPerSecond(_ samples: [Float]) -> Double {
        var crossings = 0
        for (earlier, later) in zip(samples, samples.dropFirst()) where (earlier < 0) != (later < 0) {
            crossings += 1
        }
        return Double(crossings) / (Double(samples.count) / SoundSynthesis.sampleRate)
    }

    @Test(arguments: SoundSynthesis.Loop.allCases)
    func loopsAreSeamless(loop: SoundSynthesis.Loop) throws {
        let samples = SoundSynthesis.loop(loop)
        #expect(samples.count == SoundSynthesis.frames(SoundSynthesis.loopLength(loop)))
        #expect(samples.allSatisfy { $0.isFinite && abs($0) <= 1 })
        #expect(samples.contains { abs($0) > 0.3 }, "\(loop) is not silent")
        let head = Array(samples.prefix(200))
        let tail = Array(samples.suffix(200))
        #expect(abs(Self.level(head) - Self.level(tail)) <= 0.05, "\(loop) joins at one level")
        let first = try #require(samples.first)
        let last = try #require(samples.last)
        var biggestStep: Float = 0
        for (earlier, later) in zip(samples, samples.dropFirst()) {
            biggestStep = max(biggestStep, abs(later - earlier))
        }
        #expect(abs(first - last) <= max(biggestStep, 0.05), "\(loop) runs straight from its end into its start")
    }

    static func level(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)).squareRoot()
    }

    @Test func loopSafeJoinsTheEnds() {
        let seconds = 1.0
        let raw = (0..<SoundSynthesis.frames(seconds + 0.25)).map { index -> Float in
            Float(sin(2 * .pi * 100 * SoundSynthesis.time(index)))
        }
        let looped = SoundSynthesis.loopSafe(raw, crossfade: 0.25, equalPower: false)
        #expect(looped.count == SoundSynthesis.frames(seconds))
        #expect(looped.last.map { abs($0 - raw[looped.count - 1]) < 1e-6 } == true, "the tail is untouched")
        #expect(abs(looped[0] - raw[looped.count]) < 1e-6, "the head starts where the tail left off")
        #expect(abs((looped.last ?? 0) - looped[0]) < 0.02, "a whole number of cycles meets itself")
    }

    @Test func shuffleSweepHasOneClickPerShip() {
        let click = SoundSynthesis.shuffleClick()
        #expect(click.count == SoundSynthesis.frames(0.04))
        #expect(click.prefix(SoundSynthesis.frames(0.005)).contains { abs($0) > 0.05 })
        for count in [1, 5, Timing.Stagger.maxItems] {
            let sweep = SoundSynthesis.shuffleSweep(count: count)
            let spacing = SoundSynthesis.frames(Timing.Stagger.ship)
            #expect(sweep.count == spacing * (count - 1) + click.count, "\(count) clicks")
            var onsets = 0
            for slot in 0..<Timing.Stagger.maxItems {
                let start = slot * spacing
                guard start + SoundSynthesis.frames(0.005) <= sweep.count else { break }
                let head = sweep[start..<(start + SoundSynthesis.frames(0.005))]
                if head.contains(where: { abs($0) > 0.03 }) {
                    onsets += 1
                }
                if slot + 1 < count {
                    // Quiet again before the next click.
                    let rest = sweep[(start + spacing - SoundSynthesis.frames(0.004))..<(start + spacing)]
                    #expect(rest.allSatisfy { abs($0) < 0.01 })
                }
            }
            #expect(onsets == count)
        }
        #expect(SoundSynthesis.shuffleSweep(count: 0).count == click.count)
        #expect(SoundSynthesis.shuffleSweep(count: 99).count == SoundSynthesis.shuffleSweep(count: Timing.Stagger.maxItems).count)
    }

    @Test func installOrderCoversEveryOneShot() {
        let order = SoundSynthesis.installOrder
        #expect(Set(order) == Set(FeedbackEvent.allCases).subtracting([.burning]))
        #expect(Set(order).count == order.count, "no event twice")
        #expect(order.prefix(5) == [.fire, .hit, .miss, .aim, .select], "the shots first")
        #expect(order.suffix(2) == [.firework, .thunder], "the ceremony last")
        var installed: [FeedbackEvent: Int] = [:]
        SoundSynthesis.allSamples { event, variant, samples in
            installed[event, default: 0] += 1
            #expect(variant == installed[event]! - 1, "takes arrive in order")
            #expect(!samples.isEmpty)
        }
        for event in order {
            #expect(installed[event] == SoundSynthesis.variantCount(for: event))
        }
        #expect(installed[.burning] == nil)
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
        let navigate = SoundSynthesis.samples(for: .navigate).reduce(0) { max($0, abs($1)) }
        #expect(navigate <= 0.25, "a soft tick, well under the battle")
        let theirTurn = SoundSynthesis.samples(for: .theirTurn).reduce(0) { max($0, abs($1)) }
        #expect(abs(theirTurn - 0.08) < 1e-4)
    }

    @Test func whistleLastsTheTelegraph() {
        #expect(SoundSynthesis.samples(for: .whistle).count == SoundSynthesis.frames(Timing.whistle))
    }

    @Test func ownHullSoundsAreDuller() {
        // Through the low-pass, the sound crosses zero less often: less of the roar's edge.
        #expect(Self.crossingsPerSecond(SoundSynthesis.samples(for: .hitOwn)) < Self.crossingsPerSecond(SoundSynthesis.samples(for: .hit)))
        #expect(Self.crossingsPerSecond(SoundSynthesis.samples(for: .sunkOwn)) < Self.crossingsPerSecond(SoundSynthesis.samples(for: .sunk)))
        #expect(SoundSynthesis.samples(for: .sunkOwn).count == SoundSynthesis.samples(for: .sunk).count)
    }
}

/// Records what a player is asked for: plays with their variation, engine calls, loops and scenes.
@MainActor
private final class StageRecorder: FeedbackPlayer {
    var plays: [(FeedbackEvent, FeedbackVariation)] = []
    var scenes: [AmbientScene] = []
    var loops: [(FeedbackEvent, Bool)] = []
    var prepares = 0
    var rests = 0

    func play(_ event: FeedbackEvent) {
        play(event, variation: .default)
    }

    func play(_ event: FeedbackEvent, variation: FeedbackVariation) {
        plays.append((event, variation))
    }

    func prepare() {
        prepares += 1
    }

    func rest() {
        rests += 1
    }

    func setLoop(_ event: FeedbackEvent, isOn: Bool) {
        loops.append((event, isOn))
    }

    func setAmbientScene(_ scene: AmbientScene) {
        scenes.append(scene)
    }
}

/// A player that knows only `play(_:)`: it relies on the protocol's defaults for everything else.
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
    @Test func combinedFeedbackForwardsEverything() {
        let stage = StageRecorder()
        let rumble = Rumble()
        let combined = CombinedFeedback([rumble, stage])
        let landing = FeedbackVariation(pan: 0.4, seed: 7, isMine: false, delay: Timing.shellFlight)
        combined.prepare()
        combined.play(.hit)
        combined.play(.hit, variation: landing)
        combined.setLoop(.burning, isOn: true)
        combined.setAmbientScene(.battle(.danger))
        combined.setAmbientScene(.gameOver(didWin: false))
        combined.setLoop(.burning, isOn: false)
        combined.setAmbientScene(.none)
        combined.rest()

        #expect(stage.plays.map(\.0) == [.hit, .hit])
        #expect(stage.plays.map(\.1) == [.default, landing])
        #expect(rumble.events == [.hit, .hit], "a plain player still hears every play")
        #expect(stage.loops.map(\.0) == [.burning, .burning] && stage.loops.map(\.1) == [true, false])
        #expect(stage.scenes == [.battle(.danger), .gameOver(didWin: false), .none])
        #expect(stage.prepares == 1 && stage.rests == 1)
    }

    @Test func hooksAreOptionalForAPlayer() {
        let rumble = Rumble()
        rumble.prepare()
        rumble.setLoop(.burning, isOn: true)
        rumble.setAmbientScene(.lobby)
        rumble.rest()
        #expect(rumble.events.isEmpty)
    }

    @Test func theOldSwitchMapsToScenes() {
        let stage = StageRecorder()
        stage.setAmbience(true)
        stage.setAmbience(false)
        #expect(stage.scenes == [.lobby, .none])
    }

    @Test func theDefaultVariationIsPlain() {
        let plain = FeedbackVariation.default
        #expect(plain == FeedbackVariation())
        #expect(plain.intensity == 1 && plain.pan == 0 && plain.seed == 0 && plain.isMine && !plain.isFinal && plain.count == 1 && plain.delay == 0)
        #expect(FeedbackVariation(pan: 0.6) != plain)
    }

    @Test func theRecorderRecordsVariations() {
        let recorder = FeedbackRecorder()
        let shot = FeedbackVariation(intensity: 0.8, pan: -0.6, seed: 42, isMine: true, isFinal: false, count: 1, delay: Timing.shellFlight)
        recorder.play(.fire)
        recorder.play(.sunk, variation: shot)
        recorder.prepare()
        recorder.setLoop(.burning, isOn: true)
        recorder.setAmbientScene(.placement)
        recorder.rest()
        #expect(recorder.events == [.fire, .sunk])
        #expect(recorder.plays == [FeedbackRecorder.Play(event: .fire, variation: .default), FeedbackRecorder.Play(event: .sunk, variation: shot)])
        #expect(recorder.variation(of: .sunk) == shot)
        #expect(recorder.variation(of: .fire) == .default)
        #expect(recorder.variation(of: .miss) == nil)
        #expect(recorder.loops == [FeedbackRecorder.LoopChange(event: .burning, isOn: true)])
        #expect(recorder.scenes == [.placement])
        #expect(recorder.prepareCount == 1 && recorder.restCount == 1)
    }

    @Test func theAppDrivesTheEnginesAndTheBed() {
        let (app, feedback) = makeTestApp()
        app.appDidBecomeActive()
        #expect(feedback.prepareCount == 1)
        #expect(feedback.scenes.last == .lobby, "active with ambience on: the lobby's sea")

        app.settings.ambientSoundEnabled = false
        app.ambienceSettingDidChange()
        #expect(feedback.scenes.last == AmbientScene.none)
        app.settings.ambientSoundEnabled = true
        app.ambienceSettingDidChange()
        #expect(feedback.scenes.last == .lobby)
        app.settings.soundEnabled = false
        app.ambienceSettingDidChange()
        #expect(feedback.scenes.last == AmbientScene.none, "no sound, no sea")
        app.settings.soundEnabled = true

        app.setAmbientScene(.battle(.ready))
        #expect(feedback.scenes.last == .battle(.ready))
        app.appDidEnterBackground()
        #expect(feedback.scenes.last == AmbientScene.none && feedback.restCount == 1)
        app.setAmbientScene(.placement)
        #expect(feedback.scenes.last == AmbientScene.none, "still in the background")
        app.appDidBecomeActive()
        #expect(feedback.prepareCount == 2)
        #expect(feedback.scenes.last == .placement, "the scene asked for while away comes back")
    }
}
