import Foundation

/// Synthesises the game's sound effects in code, so the app ships no recordings: the boom of a
/// gun, a shell exploding or splashing, a radar ping when aiming, the whistle of an incoming shell,
/// short fanfares at the end, and the loops of the ambient bed under it all. Shots are played when
/// they land, so every sound starts at once: the shell's flight is the picture's business
/// (`Timing.shellFlight`). Takes of a sound differ by their own noise, a ±3 % detune and ±10 % on
/// their decays, so no two shots sound the same without a pitch unit in the engine.
enum SoundSynthesis {
    static let sampleRate: Double = 44_100

    // MARK: Events

    /// How many pre-rendered takes `event` has: three for the shots and shells, two for the sounds
    /// with a second flavour (`lastShip` is up for theirs, down for yours), one for the rest.
    static func variantCount(for event: FeedbackEvent) -> Int {
        switch event {
        case .fire, .hit, .miss, .sunk: 3
        case .hitOwn, .sunkOwn, .firework, .lastShip: 2
        default: 1
        }
    }

    /// Every take of every sound, keyed by event. Takes a moment, so call it off the main thread.
    static func allVariants() -> [FeedbackEvent: [[Float]]] {
        Dictionary(uniqueKeysWithValues: FeedbackEvent.allCases.map { ($0, variants(for: $0)) })
    }

    /// Takes of `event`'s sound, so repeats don't sound stamped out.
    static func variants(for event: FeedbackEvent) -> [[Float]] {
        (0..<variantCount(for: event)).map { samples(for: event, variant: $0) }
    }

    /// Every one-shot, take by take, in install priority order (the shots first, the ceremony
    /// last), so an engine can install each as it finishes and the early events are audible sooner.
    /// `.burning` is a loop and isn't here: see `loop(_:)`.
    static func allSamples(install: (FeedbackEvent, Int, [Float]) -> Void) {
        for event in installOrder {
            for variant in 0..<variantCount(for: event) {
                install(event, variant, samples(for: event, variant: variant))
            }
        }
    }

    /// One-shots in the order `allSamples(install:)` renders them.
    static let installOrder: [FeedbackEvent] = [
        .fire, .hit, .miss, .aim, .select, .sunk, .incoming, .whistle, .hitOwn, .sunkOwn, .nearMiss,
        .place, .invalid, .turnSting, .theirTurn, .stamp, .streak, .lastShip, .navigate, .tick,
        .lift, .rotate, .shuffle, .castOff, .opening, .matchFound, .toastSuccess, .toastError,
        .finalBlow, .victory, .defeat, .firework, .thunder,
    ]

    /// The events with a slow-motion take for the finale.
    static let slowEvents: [FeedbackEvent] = [.hit, .sunk, .sunkOwn]

    /// When the notes of the melodic cues start, so the haptic score can tap on them.
    static let noteStarts: [FeedbackEvent: [TimeInterval]] = [
        .victory: [0, 0.13, 0.26, 0.39],
        .defeat: [0, 0.28, 0.56, 0.86],
        .turnSting: [0, 0.09],
        .toastSuccess: [0, 0.1],
        .streak: [0, 0.07, 0.14],
        .lastShip: [0, 0.18],
    ]

    /// Mono samples in −1…1 for take `variant` of `event`'s sound.
    static func samples(for event: FeedbackEvent, variant: Int = 0) -> [Float] {
        let take = Take(variant: variant)
        switch event {
        case .select: return click(frequency: 1_100, volume: 0.1)
        case .aim: return ping()
        case .place: return plunk()
        case .invalid: return buzz()
        case .fire: return gunshot(take: take)
        case .incoming: return distantGun()
        case .miss: return splash(take: take)
        case .hit: return explosion(seconds: 1.3, depth: 1, take: take)
        case .sunk: return sunkExplosion(take: take)
        case .victory: return fanfare()
        case .defeat: return lament()
        case .lift: return lift()
        case .rotate: return rotateTicks()
        case .castOff: return castOff()
        case .whistle: return whistle()
        case .turnSting: return turnChime()
        case .stamp: return stamp()
        case .finalBlow: return explosionSlow()
        case .matchFound: return sonarPair()
        case .opening: return titleSlam()
        case .toastSuccess: return successChime()
        case .toastError: return twoNotes(up: false)
        case .tick: return tick()
        case .lastShip: return sting(up: variant == 0)
        case .streak: return triplePing()
        case .shuffle: return shuffleClick()
        case .hitOwn: return hitOwn(take: take)
        case .sunkOwn: return sunkOwn(take: take)
        case .nearMiss: return splashClose()
        case .theirTurn: return softTick(seconds: 0.08, frequency: 320, peak: 0.08)
        case .burning: return crackleBurst()
        case .firework: return firework(seed: UInt32(max(0, variant)))
        case .thunder: return thunder()
        case .navigate: return softTick(seconds: 0.05, frequency: 1_000, peak: 0.2)
        }
    }

    /// The finale's slow-motion take of a landing: 2.4× longer and pitched down. `nil` for an event
    /// without one.
    static func slowSamples(for event: FeedbackEvent) -> [Float]? {
        switch event {
        case .hit, .sunk:
            return explosionSlow()
        case .sunkOwn:
            // Everything slows, the groan too; what runs past the end is cut by the fade.
            var samples = lowPassed(explosionSlow(), cutoff: 1_200)
            mix(resampled(groan(), rate: 1 / 2.4), into: &samples, at: frames(0.35 * 2.4), level: 0.7)
            return fadeOut(normalized(samples, peak: 0.95), seconds: 0.3)
        default:
            return nil
        }
    }

    // MARK: Takes

    /// What tells one take from another: its own noise, a ±3 % detune and ±10 % on the decays.
    struct Take: Sendable {
        let seed: UInt32
        let detune: Double
        let decay: Double

        static let canonical = Take(variant: 0)
    }

    // MARK: Shots and shells

    static func gunshot(take: Take = .canonical) -> [Float] {
        var noise = Noise(seed: 7 &+ take.seed)
        var muffle = LowPass(cutoff: 900)
        var phase = 0.0
        let samples = (0..<frames(0.6)).map { index -> Float in
            let t = time(index)
            phase += 2 * .pi * (42 + 70 * exp(-t / 0.05)) * take.detune / sampleRate
            let thump = sin(phase) * envelope(t, attack: 0.003, decay: 0.13 * take.decay)
            let blast = muffle(noise.next()) * envelope(t, attack: 0.001, decay: 0.06 * take.decay) * 2.2
            return Float(thump * 0.9 + blast * 0.8)
        }
        return fadeOut(normalized(samples, peak: 0.85), seconds: 0.1)
    }

    /// The enemy's guns, heard from across the water.
    static func distantGun() -> [Float] {
        normalized(lowPassed(gunshot(), cutoff: 320), peak: 0.45)
    }

    /// A shell striking a hull: a deep boom, a roar of flame, a rumble, and crackling.
    static func explosion(seconds: Double, depth: Double, take: Take = .canonical) -> [Float] {
        var noise = Noise(seed: 11 &+ take.seed)
        var roar = LowPass(cutoff: 1_400)
        var rumble = LowPass(cutoff: 160)
        var phase = 0.0
        let samples = (0..<frames(seconds)).map { index -> Float in
            let t = time(index)
            let white = noise.next()
            phase += 2 * .pi * (34 + 60 * exp(-t / 0.08)) * take.detune / sampleRate
            let boom = sin(phase) * envelope(t, attack: 0.004, decay: 0.22 * depth * take.decay)
            let flame = roar(white) * envelope(t, attack: 0.002, decay: 0.28 * depth * take.decay) * 2.5
            let low = rumble(white) * envelope(t, attack: 0.02, decay: 0.5 * depth * take.decay) * 6
            let crackles = (noise.next() + 1) / 2 < 0.0025 * exp(-t / (0.35 * depth))
            return Float(boom * 0.9 + flame * 0.7 + low * 0.5 + (crackles ? noise.next() * 0.9 : 0))
        }
        return fadeOut(normalized(samples, peak: 0.95), seconds: 0.25)
    }

    /// A ship finished: the explosion, then secondary booms going off down the hull at the chain
    /// detonation's spacing.
    static func sunkExplosion(take: Take = .canonical) -> [Float] {
        var samples = explosion(seconds: 2.2, depth: 1.7, take: take)
        let booms: [(start: Double, level: Float)] = [
            (Timing.secondaryStep, 0.5), (Timing.secondaryStep * 2, 0.6), (Timing.secondaryStep * 3, 0.75),
        ]
        for (slot, boom) in booms.enumerated() {
            let secondary = Take(seed: take.seed &+ UInt32(slot + 1) &* 977, detune: take.detune * (1 + 0.04 * Double(slot)), decay: take.decay)
            mix(explosion(seconds: 0.5, depth: 0.6, take: secondary), into: &samples, at: frames(boom.start), level: boom.level)
        }
        return fadeOut(normalized(samples, peak: 0.95), seconds: 0.25)
    }

    /// The last shell of the game: the explosion in slow motion, 2.4× longer and as much lower.
    static func explosionSlow() -> [Float] {
        normalized(resampled(explosion(seconds: 1.33, depth: 1.3), rate: 1 / 2.4), peak: 0.95)
    }

    /// Their shell on your hull: the explosion through a low-pass, with the clang of the plating.
    static func hitOwn(take: Take = .canonical) -> [Float] {
        var samples = lowPassed(explosion(seconds: 1.3, depth: 1, take: take), cutoff: 1_200)
        mix(clang(seed: 61 &+ take.seed), into: &samples, at: 0, level: 0.6)
        return fadeOut(normalized(samples, peak: 0.9), seconds: 0.2)
    }

    /// Your ship going down: the sinking through a low-pass, then the hull's groan.
    static func sunkOwn(take: Take = .canonical) -> [Float] {
        var samples = lowPassed(sunkExplosion(take: take), cutoff: 1_200)
        mix(groan(), into: &samples, at: frames(0.35), level: 0.7)
        return fadeOut(normalized(samples, peak: 0.95), seconds: 0.3)
    }

    /// Steel ringing: a ring-modulated, inharmonic clang, 0.3 s.
    static func clang(seed: UInt32) -> [Float] {
        var noise = Noise(seed: seed)
        var edge = LowPass(cutoff: 4_000)
        let samples = (0..<frames(0.3)).map { index -> Float in
            let t = time(index)
            let carrier = sin(2 * .pi * 1_150 * t) + 0.5 * sin(2 * .pi * 2_870 * t)
            let ring = carrier * (1 + 0.8 * sin(2 * .pi * 263 * t))
            let body = ring * envelope(t, attack: 0.001, decay: 0.07)
            let scrape = edge(noise.next()) * envelope(t, attack: 0.0005, decay: 0.008) * 2
            return Float(body * 0.8 + scrape * 0.5)
        }
        return normalized(samples, peak: 0.7)
    }

    /// The hull's groan as she goes: a low, creaking tone that bends down, 1.8 s.
    static func groan() -> [Float] {
        var noise = Noise(seed: 77)
        var body = LowPass(cutoff: 500)
        var phase = 0.0
        var creakPhase = 0.0
        let seconds = 1.8
        let samples = (0..<frames(seconds)).map { index -> Float in
            let t = time(index)
            let progress = t / seconds
            creakPhase += 2 * .pi * (7 + 4 * progress) / sampleRate
            let wobble = sin(creakPhase) * (0.3 + 0.5 * progress)
            phase += 2 * .pi * 58 * (1 - 0.15 * progress) * (1 + 0.08 * wobble) / sampleRate
            let creak = sin(phase) + 0.5 * sin(2 * phase) + 0.3 * sin(3 * phase)
            let grit = body(noise.next()) * 0.6
            let level = min(1, t / 0.25) * min(1, (seconds - t) / 0.4) * (0.7 + 0.3 * sin(2 * .pi * 1.5 * t))
            return Float((creak * 0.5 + grit * abs(creak)) * level)
        }
        return normalized(samples, peak: 0.6)
    }

    /// A shell falling into open water.
    static func splash(take: Take = .canonical) -> [Float] {
        var noise = Noise(seed: 23 &+ take.seed)
        var upper = LowPass(cutoff: 3_200 * take.detune)
        var lower = LowPass(cutoff: 500 * take.detune)
        var phase = 0.0
        let samples = (0..<frames(0.8)).map { index -> Float in
            let t = time(index)
            let white = noise.next()
            let spray = upper(white) - lower(white)
            let wash = spray * (envelope(t, attack: 0.012, decay: 0.16 * take.decay) * 2 + envelope(t, attack: 0.05, decay: 0.35 * take.decay) * 0.6)
            phase += 2 * .pi * (120 + 160 * exp(-t / 0.03)) * take.detune / sampleRate
            let plop = sin(phase) * envelope(t, attack: 0.002, decay: 0.05) * 0.5
            return Float(wash + plop)
        }
        return fadeOut(normalized(samples, peak: 0.7), seconds: 0.15)
    }

    /// A splash right beside a hull: the splash with a bright overtone as the column goes up.
    static func splashClose() -> [Float] {
        var samples = splash()
        let overtone = (0..<frames(0.2)).map { index -> Float in
            let t = time(index)
            return Float(sin(2 * .pi * 2_400 * t) * envelope(t, attack: 0.002, decay: 0.05))
        }
        mix(overtone, into: &samples, at: frames(0.01), level: 0.35)
        return fadeOut(normalized(samples, peak: 0.7), seconds: 0.15)
    }

    /// The enemy's shell on its way down: a whistle falling in pitch and rising in volume for the
    /// length of the telegraph, cut off by the landing.
    static func whistle() -> [Float] {
        var noise = Noise(seed: 31)
        var upper = LowPass(cutoff: 2_600)
        var lower = LowPass(cutoff: 1_200)
        var phase = 0.0
        let seconds = Timing.whistle
        let samples = (0..<frames(seconds)).map { index -> Float in
            let t = time(index)
            let progress = t / seconds
            phase += 2 * .pi * 1_800 * pow(600.0 / 1_800, progress) / sampleRate
            let white = noise.next()
            let breath = (upper(white) - lower(white)) * 0.4
            let level = min(1, t / 0.08) * (0.3 + 0.7 * progress) * min(1, (seconds - t) / 0.012)
            return Float((sin(phase) * 0.8 + breath) * level)
        }
        return normalized(samples, peak: 0.4)
    }

    /// The one lightning strike of a defeat: a sub rumble that rolls away, 1.2 s.
    static func thunder() -> [Float] {
        var noise = Noise(seed: 97)
        var rumble = LowPass(cutoff: 110)
        var phase = 0.0
        let samples = (0..<frames(1.2)).map { index -> Float in
            let t = time(index)
            let white = noise.next()
            let roll = rumble(white) * (envelope(t, attack: 0.05, decay: 0.4) + (t > 0.5 ? envelope(t - 0.5, attack: 0.1, decay: 0.3) * 0.6 : 0)) * 8
            phase += 2 * .pi * (38 + 20 * exp(-t / 0.1)) / sampleRate
            let sub = sin(phase) * envelope(t, attack: 0.01, decay: 0.5)
            return Float(roll * 0.6 + sub * 0.7)
        }
        return fadeOut(normalized(samples, peak: 0.9), seconds: 0.2)
    }

    /// A firework bursting: a pop, then crackles raining down, 0.5 s.
    static func firework(seed: UInt32) -> [Float] {
        var noise = Noise(seed: 113 &+ seed &* 31)
        var edge = LowPass(cutoff: 3_500)
        let samples = (0..<frames(0.5)).map { index -> Float in
            let t = time(index)
            let pop = thump(t, at: 0, frequency: 140, decay: 0.04)
            let burst = edge(noise.next()) * envelope(t, attack: 0.0005, decay: 0.015) * 3
            let sparkle = t > 0.05 && (noise.next() + 1) / 2 < 0.004 * exp(-(t - 0.05) / 0.25)
            return Float(pop * 0.8 + burst * 0.5 + (sparkle ? noise.next() * 0.6 : 0))
        }
        return fadeOut(normalized(samples, peak: 0.6), seconds: 0.05)
    }

    /// Half a second of a fire crackling: the loop's flavour as a one-shot, so `.burning` has a
    /// sound like every other event. The stage plays the loop instead.
    static func crackleBurst() -> [Float] {
        normalized(Array(burningLoop(seconds: 0.5, cycle: 4).prefix(frames(0.5))), peak: 0.5)
    }

    // MARK: Aiming, deploying, UI

    /// A radar ping, for locking on to a target.
    static func ping() -> [Float] {
        let samples = (0..<frames(0.35)).map { index -> Float in
            let t = time(index)
            let tone = sin(2 * .pi * 1_480 * t) + 0.25 * sin(2 * .pi * 2_960 * t)
            return Float(tone * envelope(t, attack: 0.002, decay: 0.07))
        }
        return normalized(samples, peak: 0.2)
    }

    /// An opponent found: a sonar ping and its answer.
    static func sonarPair() -> [Float] {
        var samples = [Float](repeating: 0, count: frames(1.0))
        let pings: [(start: Double, frequency: Double)] = [(0, 1_480), (0.32, 1_760)]
        for ping in pings {
            let first = frames(ping.start)
            for offset in 0..<frames(0.5) where first + offset < samples.count {
                let t = time(offset)
                let tone = sin(2 * .pi * ping.frequency * t) + 0.2 * sin(2 * .pi * ping.frequency * 2 * t)
                samples[first + offset] += Float(tone * envelope(t, attack: 0.003, decay: 0.12))
            }
        }
        return fadeOut(normalized(samples, peak: 0.3), seconds: 0.1)
    }

    static func click(frequency: Double, volume: Float) -> [Float] {
        let samples = (0..<frames(0.06)).map { index -> Float in
            let t = time(index)
            return Float(sin(2 * .pi * frequency * t) * envelope(t, attack: 0.001, decay: 0.012))
        }
        return normalized(samples, peak: volume)
    }

    /// A ship settling: a click with a plop of water under it, 0.12 s.
    static func plunk() -> [Float] {
        var phase = 0.0
        let samples = (0..<frames(0.12)).map { index -> Float in
            let t = time(index)
            let click = sin(2 * .pi * 640 * t) * envelope(t, attack: 0.001, decay: 0.012)
            phase += 2 * .pi * (120 + 60 * exp(-t / 0.02)) / sampleRate
            let plop = sin(phase) * envelope(t, attack: 0.003, decay: 0.035)
            return Float(click * 0.6 + plop * 0.8)
        }
        return normalized(samples, peak: 0.2)
    }

    /// A counter step: a 15 ms click, far down at −24 dB.
    static func tick() -> [Float] {
        let samples = (0..<frames(0.015)).map { index -> Float in
            let t = time(index)
            return Float(sin(2 * .pi * 2_400 * t) * envelope(t, attack: 0.0004, decay: 0.003))
        }
        return normalized(samples, peak: Float(pow(10.0, -24.0 / 20)))
    }

    /// A soft tick with a little breath to it: the turn passing, a tab switch.
    static func softTick(seconds: Double, frequency: Double, peak: Float) -> [Float] {
        var noise = Noise(seed: 59)
        var edge = LowPass(cutoff: frequency * 2)
        let samples = (0..<frames(seconds)).map { index -> Float in
            let t = time(index)
            let tone = sin(2 * .pi * frequency * t) * envelope(t, attack: 0.001, decay: 0.006)
            let breath = edge(noise.next()) * envelope(t, attack: 0.0005, decay: 0.004) * 1.5
            return Float(tone * 0.8 + breath * 0.4)
        }
        return normalized(samples, peak: peak)
    }

    /// A ship picked up: a soft click, up.
    static func lift() -> [Float] {
        var phase = 0.0
        let samples = (0..<frames(0.07)).map { index -> Float in
            let t = time(index)
            phase += 2 * .pi * (420 + 900 * min(1, t / 0.04)) / sampleRate
            return Float(sin(phase) * envelope(t, attack: 0.002, decay: 0.018))
        }
        return normalized(samples, peak: 0.16)
    }

    /// A ship turning: two 900 Hz clicks, 60 ms apart.
    static func rotateTicks() -> [Float] {
        clickTrain(at: [0, frames(0.06)], frequency: 900, decay: 0.008, length: frames(0.11), peak: 0.2)
    }

    /// One soft click of the fleet shuffling; the stage plays one per ship, `Timing.Stagger.ship` apart.
    static func shuffleClick() -> [Float] {
        clickTrain(at: [0], frequency: 700, decay: 0.006, length: frames(0.04), peak: 0.12)
    }

    /// `count` shuffle clicks `Timing.Stagger.ship` apart: the whole sweep as one buffer, each
    /// click exactly `frames(Timing.Stagger.ship)` after the last.
    static func shuffleSweep(count: Int) -> [Float] {
        let clicks = min(max(count, 1), Timing.Stagger.maxItems)
        let spacing = frames(Timing.Stagger.ship)
        let starts = (0..<clicks).map { $0 * spacing }
        return clickTrain(at: starts, frequency: 700, decay: 0.006, length: spacing * (clicks - 1) + frames(0.04), peak: 0.12)
    }

    /// Two short low blips: "not there".
    static func buzz() -> [Float] {
        let samples = (0..<frames(0.26)).map { index -> Float in
            let t = time(index)
            let blip = t < 0.09 ? t : (t >= 0.14 && t < 0.23 ? t - 0.14 : -1)
            guard blip >= 0 else { return 0 }
            let tone = sin(2 * .pi * 150 * t) + sin(2 * .pi * 450 * t) / 3 + sin(2 * .pi * 750 * t) / 5
            return Float(tone * envelope(blip, attack: 0.004, decay: 0.03))
        }
        return normalized(samples, peak: 0.3)
    }

    /// The fleet casts off: two rigid clicks as the locks close, then a whoosh sweeping up and away.
    static func castOff() -> [Float] {
        var noise = Noise(seed: 47)
        var low = LowPass(cutoff: 300)
        var mid = LowPass(cutoff: 900)
        var high = LowPass(cutoff: 2_400)
        let seconds = 0.7
        var samples = (0..<frames(seconds)).map { index -> Float in
            let t = time(index)
            let white = noise.next()
            let lowBand = low(white)
            let midBand = mid(white)
            let highBand = high(white)
            guard t >= 0.2, t <= 0.65 else { return 0 }
            let progress = min(1, (t - 0.2) / 0.4)
            let band = (midBand - lowBand) * (1 - progress) + (highBand - midBand) * progress
            return Float(band * sin(.pi * progress) * 0.6)
        }
        mix(clickTrain(at: [0, frames(0.09)], frequency: 1_200, decay: 0.008, length: frames(0.15), peak: 0.5), into: &samples, at: 0, level: 1)
        return fadeOut(normalized(samples, peak: 0.55), seconds: 0.08)
    }

    /// The SUNK stamp coming down: a 60 Hz thump with a burst of noise on top, 0.18 s.
    static func stamp() -> [Float] {
        var noise = Noise(seed: 41)
        var edge = LowPass(cutoff: 1_800)
        let samples = (0..<frames(0.18)).map { index -> Float in
            let t = time(index)
            let body = thump(t, at: 0, frequency: 60, decay: 0.07)
            let burst = edge(noise.next()) * envelope(t, attack: 0.0005, decay: 0.012) * 3
            return Float(body * 0.9 + burst * 0.5)
        }
        return fadeOut(normalized(samples, peak: 0.8), seconds: 0.03)
    }

    /// BATTLE STATIONS: two thumps as the title slams, with a 0.6 s drone under them.
    static func titleSlam() -> [Float] {
        var noise = Noise(seed: 83)
        var edge = LowPass(cutoff: 1_800)
        let drone = [55.0, 82.41, 110.0, 164.81]
        var phases = [Double](repeating: 0, count: drone.count)
        let seconds = 0.9
        let samples = (0..<frames(seconds)).map { index -> Float in
            let t = time(index)
            var tone = 0.0
            for (slot, frequency) in drone.enumerated() {
                phases[slot] += 2 * .pi * frequency / sampleRate
                tone += sin(phases[slot]) / Double(slot + 1)
            }
            let droneLevel = min(1, t / 0.02) * exp(-t / 0.3)
            let thumps = thump(t, at: 0, frequency: 60, decay: 0.09) + thump(t, at: 0.18, frequency: 55, decay: 0.09) * 0.8
            let bursts = envelope(t, attack: 0.001, decay: 0.02) + (t >= 0.18 ? envelope(t - 0.18, attack: 0.001, decay: 0.02) * 0.8 : 0)
            return Float(tone * 0.45 * droneLevel + thumps + edge(noise.next()) * bursts * 1.8)
        }
        return fadeOut(normalized(samples, peak: 0.8), seconds: 0.2)
    }

    /// Your turn: a two-note chime, C5 to G5, 0.3 s.
    static func turnChime() -> [Float] {
        let starts = noteStarts[.turnSting] ?? [0, 0.09]
        return chords(
            [Note(start: starts[0], frequency: 523.25, length: 0.12), Note(start: starts[1], frequency: 783.99, length: 0.22)],
            seconds: 0.45,
            brightness: 0.9,
            peak: 0.32
        )
    }

    /// Good news: a soft two-note chime, up, 0.25 s.
    static func successChime() -> [Float] {
        let starts = noteStarts[.toastSuccess] ?? [0, 0.1]
        return chords(
            [Note(start: starts[0], frequency: 783.99, length: 0.1), Note(start: starts[1], frequency: 1_046.50, length: 0.16)],
            seconds: 0.4,
            brightness: 0.7,
            peak: 0.28
        )
    }

    /// A toast: two notes, up for good news and down for bad.
    static func twoNotes(up: Bool) -> [Float] {
        let notes = up
            ? [Note(start: 0, frequency: 783.99, length: 0.12), Note(start: 0.11, frequency: 1_046.50, length: 0.28)]
            : [Note(start: 0, frequency: 440.00, length: 0.14), Note(start: 0.13, frequency: 329.63, length: 0.3)]
        return chords(notes, seconds: 0.7, brightness: up ? 0.8 : 0.45, peak: 0.3)
    }

    /// One ship left: a two-note sting, up for theirs and down for yours, 0.5 s.
    static func sting(up: Bool) -> [Float] {
        let starts = noteStarts[.lastShip] ?? [0, 0.18]
        let notes = up
            ? [Note(start: starts[0], frequency: 220.00, length: 0.16), Note(start: starts[1], frequency: 329.63, length: 0.3)]
            : [Note(start: starts[0], frequency: 329.63, length: 0.16), Note(start: starts[1], frequency: 220.00, length: 0.3)]
        return chords(notes, seconds: 0.6, brightness: 0.6, peak: 0.4)
    }

    /// A streak chip: three rising pings, G5, B5, D6.
    static func triplePing() -> [Float] {
        let starts = noteStarts[.streak] ?? [0, 0.07, 0.14]
        var samples = [Float](repeating: 0, count: frames(0.35))
        for (slot, frequency) in [783.99, 987.77, 1_174.66].enumerated() {
            let start = frames(starts[min(slot, starts.count - 1)])
            for offset in 0..<frames(0.1) where start + offset < samples.count {
                let t = time(offset)
                let tone = sin(2 * .pi * frequency * t) + 0.3 * sin(2 * .pi * frequency * 2 * t)
                samples[start + offset] += Float(tone * envelope(t, attack: 0.001, decay: 0.02))
            }
        }
        return normalized(samples, peak: 0.25)
    }

    /// A rising arpeggio into a held major chord.
    static func fanfare() -> [Float] {
        let starts = noteStarts[.victory] ?? [0, 0.13, 0.26, 0.39]
        return chords(
            [
                Note(start: starts[0], frequency: 392.00, length: 0.16),
                Note(start: starts[1], frequency: 523.25, length: 0.16),
                Note(start: starts[2], frequency: 659.25, length: 0.16),
                Note(start: starts[3], frequency: 783.99, length: 0.9),
                Note(start: starts[3], frequency: 523.25, length: 0.9),
                Note(start: starts[3], frequency: 659.25, length: 0.9),
                Note(start: starts[3], frequency: 1_046.50, length: 0.9),
            ],
            seconds: 1.7,
            brightness: 1,
            peak: 0.6
        )
    }

    /// A slow fall to a minor chord.
    static func lament() -> [Float] {
        let starts = noteStarts[.defeat] ?? [0, 0.28, 0.56, 0.86]
        return chords(
            [
                Note(start: starts[0], frequency: 392.00, length: 0.3),
                Note(start: starts[1], frequency: 311.13, length: 0.3),
                Note(start: starts[2], frequency: 261.63, length: 0.35),
                Note(start: starts[3], frequency: 196.00, length: 1.1),
                Note(start: starts[3], frequency: 233.08, length: 1.1),
                Note(start: starts[3], frequency: 293.66, length: 1.1),
            ],
            seconds: 2.3,
            brightness: 0.5,
            peak: 0.5
        )
    }

    // MARK: Loops

    /// The seamless loops of the ambient bed and the fire. Not events: the stage runs them on
    /// their own voices.
    enum Loop: CaseIterable, Sendable {
        case burning, rain, wind, swell, hum, tension, sonarRoom
    }

    /// How long `loop` runs before it joins its start.
    static func loopLength(_ loop: Loop) -> Double {
        switch loop {
        case .swell, .sonarRoom: 8
        case .burning, .rain, .wind, .hum, .tension: 4
        }
    }

    /// How much of each loop's tail is crossfaded into its start.
    static let loopCrossfade = 0.5

    /// The samples of `loop`, exactly `loopLength` long, with the last `loopCrossfade` seconds
    /// blended into the start so it joins without a click.
    static func loop(_ loop: Loop) -> [Float] {
        let cycle = loopLength(loop)
        let seconds = cycle + loopCrossfade
        switch loop {
        case .burning: return loopSafe(burningLoop(seconds: seconds, cycle: cycle), crossfade: loopCrossfade)
        case .rain: return loopSafe(rainLoop(seconds: seconds, cycle: cycle), crossfade: loopCrossfade)
        case .wind: return loopSafe(windLoop(seconds: seconds, cycle: cycle), crossfade: loopCrossfade)
        case .swell: return loopSafe(swellLoop(seconds: seconds, cycle: cycle), crossfade: loopCrossfade)
        case .hum: return loopSafe(humLoop(seconds: seconds, cycle: cycle), crossfade: loopCrossfade, equalPower: false)
        case .tension: return loopSafe(tensionLoop(seconds: seconds, cycle: cycle), crossfade: loopCrossfade, equalPower: false)
        case .sonarRoom: return loopSafe(sonarRoomLoop(seconds: seconds, cycle: cycle), crossfade: loopCrossfade)
        }
    }

    /// `samples` with their last `seconds` blended into their start and then dropped, so the result
    /// loops seamlessly: its last sample runs straight into its first. Equal-power weights suit
    /// noise; linear weights suit tones that repeat every loop.
    static func loopSafe(_ samples: [Float], crossfade seconds: Double, equalPower: Bool = true) -> [Float] {
        let fade = min(frames(seconds), samples.count / 2)
        guard fade > 0 else { return samples }
        let length = samples.count - fade
        var looped = Array(samples[0..<length])
        for index in 0..<fade {
            let progress = Double(index) / Double(fade)
            let head = equalPower ? sin(progress * .pi / 2) : progress
            let tail = equalPower ? cos(progress * .pi / 2) : 1 - progress
            looped[index] = Float(Double(samples[index]) * head + Double(samples[length + index]) * tail)
        }
        return looped
    }

    /// A fire: a low roar that breathes, with crackles on top.
    static func burningLoop(seconds: Double, cycle: Double) -> [Float] {
        var noise = Noise(seed: 131)
        var roar = LowPass(cutoff: 700)
        var flames = LowPass(cutoff: 2_200)
        var crackle = 0.0
        let samples = (0..<frames(seconds)).map { index -> Float in
            let t = time(index)
            let white = noise.next()
            let low = roar(white)
            let mid = flames(white) - low
            let flicker = 0.75 + 0.15 * sin(2 * .pi * 2 * t / cycle) + 0.1 * sin(2 * .pi * 5 * t / cycle + 1.3)
            if (noise.next() + 1) / 2 < 0.0008 {
                crackle = 0.4 + 0.6 * (noise.next() + 1) / 2
            }
            let snap = crackle * noise.next()
            crackle *= 0.985
            return Float(low * 2.5 * flicker + mid * 0.35 * flicker + snap * 0.9)
        }
        return normalized(samples, peak: 0.55)
    }

    /// Rain: steady hiss with droplets ticking through it.
    static func rainLoop(seconds: Double, cycle: Double) -> [Float] {
        var noise = Noise(seed: 139)
        var upper = LowPass(cutoff: 6_000)
        var lower = LowPass(cutoff: 1_500)
        var drop = 0.0
        var phase = 0.0
        let samples = (0..<frames(seconds)).map { index -> Float in
            let t = time(index)
            let white = noise.next()
            let hiss = (upper(white) - lower(white)) * (0.9 + 0.1 * sin(2 * .pi * t / cycle))
            if (noise.next() + 1) / 2 < 0.0005 {
                drop = 0.5 + 0.5 * (noise.next() + 1) / 2
            }
            phase += 2 * .pi * 3_100 / sampleRate
            let blip = drop * sin(phase)
            drop *= 0.9985
            return Float(hiss * 0.5 + blip * 0.6)
        }
        return normalized(samples, peak: 0.5)
    }

    /// Wind: filtered noise with gusts that come and go a whole number of times per loop.
    static func windLoop(seconds: Double, cycle: Double) -> [Float] {
        var noise = Noise(seed: 101)
        var wind = LowPass(cutoff: 420)
        var hiss = LowPass(cutoff: 2_400)
        let samples = (0..<frames(seconds)).map { index -> Float in
            let t = time(index)
            let white = noise.next()
            let low = wind(white)
            let mid = hiss(white)
            let breeze = low * 1.6 + (mid - low) * 0.12
            let gusts = 0.8 + 0.12 * sin(2 * .pi * 2 * t / cycle) + 0.08 * sin(2 * .pi * 3 * t / cycle + 0.7)
            return Float(breeze * gusts)
        }
        return normalized(samples, peak: 0.5)
    }

    /// Swell: one wash of water per loop, rising from a quiet trough at the seam and back.
    static func swellLoop(seconds: Double, cycle: Double) -> [Float] {
        var noise = Noise(seed: 107)
        var wash = LowPass(cutoff: 900)
        var deep = LowPass(cutoff: 200)
        let samples = (0..<frames(seconds)).map { index -> Float in
            let t = time(index)
            let white = noise.next()
            let body = wash(white)
            let low = deep(white)
            let hump = pow(0.5 - 0.5 * cos(2 * .pi * t / cycle), 2.5)
            return Float((body - low) * (0.15 + 0.85 * hump) + low * 1.2 * (0.3 + 0.7 * hump))
        }
        return normalized(samples, peak: 0.5)
    }

    /// A diesel hum: 55 Hz and its harmonics, throbbing slowly, with a little grit.
    static func humLoop(seconds: Double, cycle: Double) -> [Float] {
        var noise = Noise(seed: 109)
        var grit = LowPass(cutoff: 240)
        let voices: [(frequency: Double, weight: Double)] = [(55, 1), (55.25, 0.7), (110, 0.6), (165, 0.35), (220, 0.2)]
        var phases = [Double](repeating: 0, count: voices.count)
        let samples = (0..<frames(seconds)).map { index -> Float in
            let t = time(index)
            var tone = 0.0
            for (slot, voice) in voices.enumerated() {
                phases[slot] += 2 * .pi * voice.frequency / sampleRate
                tone += sin(phases[slot]) * voice.weight
            }
            let throb = 0.8 + 0.2 * sin(2 * .pi * 2 * t / cycle)
            return Float(tone * throb + grit(noise.next()) * 0.3)
        }
        return normalized(samples, peak: 0.5)
    }

    /// Tension: a detuned low drone with a tritone in it, beating slowly, swelling once per loop.
    static func tensionLoop(seconds: Double, cycle: Double) -> [Float] {
        let voices: [(frequency: Double, weight: Double)] = [(55, 1), (55.5, 0.9), (77.75, 0.5), (110, 0.4), (111, 0.3), (155.5, 0.2)]
        var phases = [Double](repeating: 0, count: voices.count)
        let samples = (0..<frames(seconds)).map { index -> Float in
            let t = time(index)
            var tone = 0.0
            for (slot, voice) in voices.enumerated() {
                phases[slot] += 2 * .pi * voice.frequency / sampleRate
                tone += sin(phases[slot]) * voice.weight
            }
            let swell = 0.7 + 0.3 * sin(2 * .pi * t / cycle - .pi / 2)
            return Float(tone * swell)
        }
        return normalized(samples, peak: 0.5)
    }

    /// The sonar room: a faint room tone and a 1.2 kHz ping once per loop, with decaying echoes.
    static func sonarRoomLoop(seconds: Double, cycle: Double) -> [Float] {
        var noise = Noise(seed: 127)
        var room = LowPass(cutoff: 300)
        let echoes: [(start: Double, level: Double)] = [(1.0, 1), (1.55, 0.45), (2.1, 0.2), (2.65, 0.09)]
        let samples = (0..<frames(seconds)).map { index -> Float in
            let t = time(index)
            var ping = 0.0
            for echo in echoes where t >= echo.start {
                let s = t - echo.start
                ping += sin(2 * .pi * 1_200 * s) * envelope(s, attack: 0.002, decay: 0.18) * echo.level
            }
            return Float(room(noise.next()) * 0.8 + ping * 0.6)
        }
        return normalized(samples, peak: 0.5)
    }

    // MARK: Building blocks

    struct Note {
        let start: Double
        let frequency: Double
        let length: Double
    }

    /// Notes with a brassy tone: a few harmonics, quieter as they go up.
    static func chords(_ notes: [Note], seconds: Double, brightness: Double, peak: Float) -> [Float] {
        var samples = [Float](repeating: 0, count: frames(seconds))
        let harmonics = 1...4
        let strengths = harmonics.map { pow(brightness * 0.55, Double($0 - 1)) / Double($0) }
        for note in notes {
            let start = frames(note.start)
            let speeds = harmonics.map { 2 * .pi * note.frequency * Double($0) }
            for offset in 0..<frames(note.length + 0.4) where start + offset < samples.count {
                let t = time(offset)
                let level = t < 0.015 ? t / 0.015 : exp(-(t - 0.015) / (note.length * 0.6))
                var tone = 0.0
                for index in strengths.indices {
                    tone += sin(speeds[index] * t) * strengths[index]
                }
                samples[start + offset] += Float(tone * level)
            }
        }
        return fadeOut(normalized(samples, peak: peak), seconds: 0.3)
    }

    /// Clicks of `frequency` starting at the frames in `starts`, each dying away in `decay` seconds,
    /// in a buffer `length` frames long.
    static func clickTrain(at starts: [Int], frequency: Double, decay: Double, length: Int, peak: Float) -> [Float] {
        var samples = [Float](repeating: 0, count: max(1, length))
        for first in starts {
            for offset in 0..<frames(decay * 6) where first + offset < samples.count {
                let t = time(offset)
                samples[first + offset] += Float(sin(2 * .pi * frequency * t) * envelope(t, attack: 0.0008, decay: decay))
            }
        }
        return normalized(samples, peak: peak)
    }

    /// A low thump at `start`: a sine that drops onto `frequency` and dies away in `decay` seconds.
    static func thump(_ t: Double, at start: Double, frequency: Double, decay: Double) -> Double {
        let s = t - start
        guard s >= 0 else { return 0 }
        let drop = 1.5 * (1 - exp(-s / 0.03))
        return sin(2 * .pi * (frequency * s + drop)) * envelope(s, attack: 0.002, decay: decay)
    }

    /// Adds `source` × `level` into `samples` from `start`, dropping what runs past the end.
    static func mix(_ source: [Float], into samples: inout [Float], at start: Int, level: Float) {
        guard start >= 0 else { return }
        for (offset, value) in source.enumerated() where start + offset < samples.count {
            samples[start + offset] += value * level
        }
    }

    /// `samples` through a one-pole low-pass at `cutoff`.
    static func lowPassed(_ samples: [Float], cutoff: Double) -> [Float] {
        var filter = LowPass(cutoff: cutoff)
        return samples.map { Float(filter(Double($0))) }
    }

    /// `samples` played `rate` times faster, by linear interpolation: above 1 is shorter and
    /// higher in pitch, below 1 longer and lower.
    static func resampled(_ samples: [Float], rate: Double) -> [Float] {
        guard samples.count > 1, rate > 0 else { return samples }
        let count = Int(Double(samples.count) / rate)
        let last = samples.count - 1
        return (0..<count).map { index -> Float in
            let position = Double(index) * rate
            let whole = min(Int(position), last)
            let next = min(whole + 1, last)
            let fraction = Float(position - Double(whole))
            return samples[whole] + (samples[next] - samples[whole]) * fraction
        }
    }

    static func normalized(_ samples: [Float], peak: Float) -> [Float] {
        let loudest = samples.reduce(0) { max($0, abs($1)) }
        guard loudest > 0 else { return samples }
        let gain = peak / loudest
        return samples.map { $0 * gain }
    }

    static func fadeIn(_ samples: [Float], seconds: Double) -> [Float] {
        let length = min(samples.count, frames(seconds))
        guard length > 0 else { return samples }
        var faded = samples
        for index in 0..<length {
            faded[index] *= Float(index) / Float(length)
        }
        return faded
    }

    static func fadeOut(_ samples: [Float], seconds: Double) -> [Float] {
        let length = min(samples.count, frames(seconds))
        guard length > 0 else { return samples }
        var faded = samples
        for index in 0..<length {
            faded[samples.count - 1 - index] *= Float(index) / Float(length)
        }
        return faded
    }

    /// A short linear attack, then exponential decay.
    static func envelope(_ t: Double, attack: Double, decay: Double) -> Double {
        t < attack ? t / attack : exp(-(t - attack) / decay)
    }

    static func frames(_ seconds: Double) -> Int {
        Int(seconds * sampleRate)
    }

    static func time(_ frame: Int) -> Double {
        Double(frame) / sampleRate
    }

    /// Repeatable white noise.
    struct Noise {
        private var state: UInt32

        init(seed: UInt32) {
            state = seed
        }

        mutating func next() -> Double {
            state = state &* 1_664_525 &+ 1_013_904_223
            return Double(state >> 8) / Double(1 << 24) * 2 - 1
        }
    }

    /// A one-pole low-pass filter.
    struct LowPass {
        private let coefficient: Double
        private var value = 0.0

        init(cutoff: Double) {
            coefficient = 1 - exp(-2 * .pi * cutoff / SoundSynthesis.sampleRate)
        }

        mutating func callAsFunction(_ input: Double) -> Double {
            value += coefficient * (input - value)
            return value
        }
    }
}

extension SoundSynthesis.Take {
    /// Take `variant`: the canonical sound at 0, a little lower and longer at 1, higher and
    /// shorter at 2, and so on round again, each with its own noise.
    init(variant: Int) {
        let slot = max(0, variant)
        let lean: Double = [0, -1, 1][slot % 3]
        self.init(seed: UInt32(slot) &* 7_919, detune: 1 + 0.03 * lean, decay: 1 - 0.1 * lean)
    }
}
