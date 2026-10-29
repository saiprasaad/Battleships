import Foundation

/// Synthesises the game's sound effects in code, so the app ships no recordings: the boom of a
/// gun, a shell exploding or splashing, a radar ping when aiming, the whistle of an incoming shell,
/// short fanfares at the end, and the ambient bed under it all. Shots are played when they land,
/// so every sound starts at once: the shell's flight is the picture's business (`Timing.shellFlight`).
enum SoundSynthesis {
    static let sampleRate: Double = 44_100
    /// Every take of every sound, keyed by event. Takes a moment, so call it off the main thread.
    static func allVariants() -> [FeedbackEvent: [[Float]]] {
        Dictionary(uniqueKeysWithValues: FeedbackEvent.allCases.map { ($0, variants(for: $0)) })
    }

    /// Takes of `event`'s sound to play in turn, so repeats don't sound stamped out: three pitch
    /// variants (±4 %) for the shots and shells, and one take for everything else.
    static func variants(for event: FeedbackEvent) -> [[Float]] {
        let base = samples(for: event)
        switch event {
        case .fire, .hit, .miss, .sunk, .incoming:
            return [base, resampled(base, rate: 0.96), resampled(base, rate: 1.04)]
        default:
            return [base]
        }
    }

    /// Mono samples in −1…1 for `event`: the canonical take.
    static func samples(for event: FeedbackEvent) -> [Float] {
        switch event {
        case .select: click(frequency: 1_100, volume: 0.1)
        case .place: click(frequency: 640, volume: 0.18)
        case .aim: ping()
        case .invalid: buzz()
        case .fire: gunshot()
        case .incoming: distantGun()
        case .miss: splash()
        case .hit: explosion(seconds: 1.3, depth: 1)
        case .sunk: explosion(seconds: 2.2, depth: 1.7)
        case .victory: fanfare()
        case .defeat: lament()
        case .lift: lift()
        case .rotate: ratchet()
        case .castOff: horn()
        case .whistle: whistle()
        case .turnSting: turnSting()
        case .stamp: stamp()
        case .finalBlow: finalBlow()
        case .matchFound: sonarPair()
        case .opening: brassSwell()
        case .toastSuccess: twoNotes(up: true)
        case .toastError: twoNotes(up: false)
        case .tick: tick()
        case .lastShip: lowNote()
        case .streak: risingTicks()
        }
    }

    // MARK: Sounds

    static func gunshot() -> [Float] {
        var noise = Noise(seed: 7)
        var muffle = LowPass(cutoff: 900)
        var phase = 0.0
        let samples = (0..<frames(0.6)).map { index -> Float in
            let t = time(index)
            phase += 2 * .pi * (42 + 70 * exp(-t / 0.05)) / sampleRate
            let thump = sin(phase) * envelope(t, attack: 0.003, decay: 0.13)
            let blast = muffle(noise.next()) * envelope(t, attack: 0.001, decay: 0.06) * 2.2
            return Float(thump * 0.9 + blast * 0.8)
        }
        return fadeOut(normalized(samples, peak: 0.85), seconds: 0.1)
    }

    /// The enemy's guns, heard from across the water.
    static func distantGun() -> [Float] {
        var muffle = LowPass(cutoff: 320)
        let samples = gunshot().map { Float(muffle(Double($0))) }
        return normalized(samples, peak: 0.45)
    }

    /// A shell striking a hull: a deep boom, a roar of flame, a rumble, and crackling.
    static func explosion(seconds: Double, depth: Double) -> [Float] {
        var noise = Noise(seed: 11)
        var roar = LowPass(cutoff: 1_400)
        var rumble = LowPass(cutoff: 160)
        var phase = 0.0
        let samples = (0..<frames(seconds)).map { index -> Float in
            let t = time(index)
            let white = noise.next()
            phase += 2 * .pi * (34 + 60 * exp(-t / 0.08)) / sampleRate
            let boom = sin(phase) * envelope(t, attack: 0.004, decay: 0.22 * depth)
            let flame = roar(white) * envelope(t, attack: 0.002, decay: 0.28 * depth) * 2.5
            let low = rumble(white) * envelope(t, attack: 0.02, decay: 0.5 * depth) * 6
            let crackles = (noise.next() + 1) / 2 < 0.0025 * exp(-t / (0.35 * depth))
            return Float(boom * 0.9 + flame * 0.7 + low * 0.5 + (crackles ? noise.next() * 0.9 : 0))
        }
        return fadeOut(normalized(samples, peak: 0.95), seconds: 0.25)
    }

    /// The last shell of the game: the explosion in slow motion, every sample stretched by the
    /// finale's time scale.
    static func finalBlow() -> [Float] {
        normalized(resampled(explosion(seconds: 1.1, depth: 1.3), rate: Timing.finalTimeScale), peak: 0.95)
    }

    /// A shell falling into open water.
    static func splash() -> [Float] {
        var noise = Noise(seed: 23)
        var upper = LowPass(cutoff: 3_200)
        var lower = LowPass(cutoff: 500)
        var phase = 0.0
        let samples = (0..<frames(0.8)).map { index -> Float in
            let t = time(index)
            let white = noise.next()
            let spray = upper(white) - lower(white)
            let wash = spray * (envelope(t, attack: 0.012, decay: 0.16) * 2 + envelope(t, attack: 0.05, decay: 0.35) * 0.6)
            phase += 2 * .pi * (120 + 160 * exp(-t / 0.03)) / sampleRate
            let plop = sin(phase) * envelope(t, attack: 0.002, decay: 0.05) * 0.5
            return Float(wash + plop)
        }
        return fadeOut(normalized(samples, peak: 0.7), seconds: 0.15)
    }

    /// The enemy's shell on its way down: a thin whistle rising in pitch and volume for the length
    /// of the telegraph, cut off by the landing.
    static func whistle() -> [Float] {
        var noise = Noise(seed: 31)
        var upper = LowPass(cutoff: 2_600)
        var lower = LowPass(cutoff: 1_400)
        var phase = 0.0
        let seconds = Timing.whistle
        let samples = (0..<frames(seconds)).map { index -> Float in
            let t = time(index)
            let progress = t / seconds
            phase += 2 * .pi * 900 * pow(2.6, progress) / sampleRate
            let white = noise.next()
            let breath = (upper(white) - lower(white)) * 0.35
            let level = min(1, t / 0.08) * (0.35 + 0.65 * progress) * min(1, (seconds - t) / 0.012)
            return Float((sin(phase) * 0.8 + breath) * level)
        }
        return normalized(samples, peak: 0.4)
    }

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

    /// A counter step: a 15 ms click, far down at −24 dB.
    static func tick() -> [Float] {
        let samples = (0..<frames(0.015)).map { index -> Float in
            let t = time(index)
            return Float(sin(2 * .pi * 2_400 * t) * envelope(t, attack: 0.0004, decay: 0.003))
        }
        return normalized(samples, peak: Float(pow(10.0, -24.0 / 20)))
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

    /// A ship turning: a short ratchet of four clicks.
    static func ratchet() -> [Float] {
        var noise = Noise(seed: 53)
        var edge = LowPass(cutoff: 3_000)
        let spacing = 0.022
        let samples = (0..<frames(0.14)).map { index -> Float in
            let t = time(index)
            let count = Int(t / spacing)
            guard count < 4 else { return 0 }
            let since = t - Double(count) * spacing
            let tone = sin(2 * .pi * (700 + 90 * Double(count)) * since)
            return Float((tone * 0.7 + edge(noise.next()) * 1.5) * envelope(since, attack: 0.0005, decay: 0.004))
        }
        return normalized(samples, peak: 0.22)
    }

    /// A streak chip: three quick ticks, rising.
    static func risingTicks() -> [Float] {
        var samples = [Float](repeating: 0, count: frames(0.3))
        for (slot, frequency) in [1_200.0, 1_500.0, 1_900.0].enumerated() {
            let start = frames(Double(slot) * 0.07)
            for offset in 0..<frames(0.05) where start + offset < samples.count {
                let t = time(offset)
                samples[start + offset] += Float(sin(2 * .pi * frequency * t) * envelope(t, attack: 0.001, decay: 0.012))
            }
        }
        return normalized(samples, peak: 0.25)
    }

    /// The SUNK stamp coming down: a dull thump with a click on top.
    static func stamp() -> [Float] {
        var noise = Noise(seed: 41)
        var edge = LowPass(cutoff: 2_200)
        var body = LowPass(cutoff: 240)
        var phase = 0.0
        let samples = (0..<frames(0.4)).map { index -> Float in
            let t = time(index)
            phase += 2 * .pi * (48 + 60 * exp(-t / 0.03)) / sampleRate
            let thump = sin(phase) * envelope(t, attack: 0.002, decay: 0.11)
            let white = noise.next()
            let click = edge(white) * envelope(t, attack: 0.0005, decay: 0.006) * 3
            let wood = body(white) * envelope(t, attack: 0.001, decay: 0.05) * 4
            return Float(thump * 0.9 + click * 0.5 + wood * 0.4)
        }
        return fadeOut(normalized(samples, peak: 0.8), seconds: 0.08)
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

    /// Your turn: two bright notes, up.
    static func turnSting() -> [Float] {
        chords(
            [
                Note(start: 0, frequency: 1_046.50, length: 0.14),
                Note(start: 0.12, frequency: 1_318.51, length: 0.32),
            ],
            seconds: 0.75,
            brightness: 0.9,
            peak: 0.32
        )
    }

    /// A toast: two notes, up for good news and down for bad.
    static func twoNotes(up: Bool) -> [Float] {
        let notes = up
            ? [Note(start: 0, frequency: 783.99, length: 0.12), Note(start: 0.11, frequency: 1_046.50, length: 0.28)]
            : [Note(start: 0, frequency: 440.00, length: 0.14), Note(start: 0.13, frequency: 329.63, length: 0.3)]
        return chords(notes, seconds: 0.7, brightness: up ? 0.8 : 0.45, peak: 0.3)
    }

    /// A rising arpeggio into a held major chord.
    static func fanfare() -> [Float] {
        chords(
            [
                Note(start: 0, frequency: 392.00, length: 0.16),
                Note(start: 0.13, frequency: 523.25, length: 0.16),
                Note(start: 0.26, frequency: 659.25, length: 0.16),
                Note(start: 0.39, frequency: 783.99, length: 0.9),
                Note(start: 0.39, frequency: 523.25, length: 0.9),
                Note(start: 0.39, frequency: 659.25, length: 0.9),
                Note(start: 0.39, frequency: 1_046.50, length: 0.9),
            ],
            seconds: 1.7,
            brightness: 1,
            peak: 0.6
        )
    }

    /// A slow fall to a minor chord.
    static func lament() -> [Float] {
        chords(
            [
                Note(start: 0, frequency: 392.00, length: 0.3),
                Note(start: 0.28, frequency: 311.13, length: 0.3),
                Note(start: 0.56, frequency: 261.63, length: 0.35),
                Note(start: 0.86, frequency: 196.00, length: 1.1),
                Note(start: 0.86, frequency: 233.08, length: 1.1),
                Note(start: 0.86, frequency: 293.66, length: 1.1),
            ],
            seconds: 2.3,
            brightness: 0.5,
            peak: 0.5
        )
    }

    /// BATTLE STATIONS: a low brass swell, growing brighter as it fills.
    static func brassSwell() -> [Float] {
        let seconds = 0.9
        let frequencies = [98.0, 146.83, 196.0]
        let harmonics = [1.0, 2.0, 3.0, 4.0, 5.0]
        var phases = [Double](repeating: 0, count: frequencies.count * harmonics.count * 2)
        let samples = (0..<frames(seconds)).map { index -> Float in
            let t = time(index)
            let rise = min(1, t / 0.55)
            let level = rise * rise * min(1, (seconds - t) / 0.2)
            let brightness = 0.45 + 0.4 * rise
            var tone = 0.0
            for (f, frequency) in frequencies.enumerated() {
                for (h, harmonic) in harmonics.enumerated() {
                    let slot = (f * harmonics.count + h) * 2
                    phases[slot] += 2 * .pi * frequency * harmonic / sampleRate
                    phases[slot + 1] += 2 * .pi * frequency * 1.003 * harmonic / sampleRate
                    tone += (sin(phases[slot]) + sin(phases[slot + 1])) * pow(brightness, harmonic - 1)
                }
            }
            return Float(tone * level)
        }
        return normalized(samples, peak: 0.5)
    }

    /// The fleet casts off: a ship's horn, its pitch rising into the note as it fills.
    static func horn() -> [Float] {
        let seconds = 0.7
        let voices: [(frequency: Double, weight: Double)] = [(110, 1), (165, 0.55), (220, 0.35)]
        let harmonics = [1.0, 3.0, 5.0, 7.0]
        var phases = [Double](repeating: 0, count: voices.count * harmonics.count)
        let samples = (0..<frames(seconds)).map { index -> Float in
            let t = time(index)
            let level = min(1, t / 0.06) * min(1, (seconds - t) / 0.18)
            let sag = 1 - 0.05 * exp(-t / 0.08)
            var tone = 0.0
            for (v, voice) in voices.enumerated() {
                for (h, harmonic) in harmonics.enumerated() {
                    let slot = v * harmonics.count + h
                    phases[slot] += 2 * .pi * voice.frequency * sag * harmonic / sampleRate
                    tone += sin(phases[slot]) * voice.weight / harmonic
                }
            }
            return Float(tone * level)
        }
        return normalized(samples, peak: 0.55)
    }

    /// One ship left: a single low note, held and sinking a little.
    static func lowNote() -> [Float] {
        let seconds = 1.3
        let harmonics = [1.0, 2.0, 3.0, 4.0, 5.0]
        var phases = [Double](repeating: 0, count: harmonics.count * 2)
        let samples = (0..<frames(seconds)).map { index -> Float in
            let t = time(index)
            let frequency = 73.42 * (1 - 0.03 * t / seconds)
            let level = min(1, t / 0.05) * exp(-t / 0.9)
            var tone = 0.0
            for (h, harmonic) in harmonics.enumerated() {
                phases[h] += 2 * .pi * frequency * harmonic / sampleRate
                phases[h + harmonics.count] += 2 * .pi * frequency * 1.004 * harmonic / sampleRate
                tone += (sin(phases[h]) + sin(phases[h + harmonics.count])) / harmonic
            }
            return Float(tone * level)
        }
        return fadeOut(normalized(samples, peak: 0.5), seconds: 0.3)
    }

    /// A seamless loop of sea and bridge under everything: filtered wind, a slow swell in its level
    /// (about 0.08 Hz, rounded to whole cycles so the loop joins), a faint hum and a faint sonar
    /// ping. The tail is cross-blended into the head and both ends fade, so it loops without a click.
    static func ambientBed(seconds: Double = 8) -> [Float] {
        let total = frames(seconds)
        let blend = frames(1.0)
        var noise = Noise(seed: 101)
        var wind = LowPass(cutoff: 420)
        var hiss = LowPass(cutoff: 2_400)
        let swellRate = max(1, (seconds * 0.08).rounded()) / seconds
        var raw = [Float](repeating: 0, count: total + blend)
        for index in 0..<raw.count {
            let t = time(index)
            let white = noise.next()
            let low = wind(white)
            let mid = hiss(white)
            let breeze = low * 1.6 + (mid - low) * 0.12
            // The trough of the swell sits at the seam, where the ends fade anyway.
            let swell = 0.55 + 0.45 * (0.5 - 0.5 * cos(2 * .pi * swellRate * t))
            let gusts = 0.8 + 0.12 * sin(2 * .pi * 2 * t / seconds) + 0.08 * sin(2 * .pi * 3 * t / seconds + 0.7)
            let hum = 0.05 * sin(2 * .pi * 52 * t)
            let sincePing = t - seconds / 2
            let ping = sincePing >= 0 && sincePing < 1 ? sin(2 * .pi * 1_100 * sincePing) * exp(-sincePing / 0.25) * 0.12 : 0
            raw[index] = Float(breeze * swell * gusts + hum + ping)
        }
        var bed = Array(raw[0..<total])
        for index in 0..<blend {
            let mix = Float(index) / Float(blend)
            bed[index] = bed[index] * mix + raw[total + index] * (1 - mix)
        }
        return fadeIn(fadeOut(normalized(bed, peak: 0.25), seconds: 0.2), seconds: 0.2)
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
