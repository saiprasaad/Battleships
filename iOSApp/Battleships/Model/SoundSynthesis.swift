import Foundation

/// Synthesises the game's sound effects in code, so the app ships no recordings: the boom of a
/// gun, a shell exploding or splashing, a radar ping when aiming, and short fanfares at the end.
enum SoundSynthesis {
    static let sampleRate: Double = 44_100
    /// Shells take this long to land, so the explosion or splash starts with silence.
    static let flightTime: Double = 0.16

    /// Mono samples in −1…1 for `event`.
    static func samples(for event: FeedbackEvent) -> [Float] {
        switch event {
        case .select: click(frequency: 1_100, volume: 0.1)
        case .place: click(frequency: 640, volume: 0.18)
        case .aim: ping()
        case .invalid: buzz()
        case .fire: gunshot()
        case .miss: delayed(splash())
        case .hit: delayed(explosion(seconds: 1.3, depth: 1))
        case .sunk: delayed(explosion(seconds: 2.2, depth: 1.7))
        case .victory: fanfare()
        case .defeat: lament()
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

    /// A radar ping, for locking on to a target.
    static func ping() -> [Float] {
        let samples = (0..<frames(0.35)).map { index -> Float in
            let t = time(index)
            let tone = sin(2 * .pi * 1_480 * t) + 0.25 * sin(2 * .pi * 2_960 * t)
            return Float(tone * envelope(t, attack: 0.002, decay: 0.07))
        }
        return normalized(samples, peak: 0.2)
    }

    static func click(frequency: Double, volume: Float) -> [Float] {
        let samples = (0..<frames(0.06)).map { index -> Float in
            let t = time(index)
            return Float(sin(2 * .pi * frequency * t) * envelope(t, attack: 0.001, decay: 0.012))
        }
        return normalized(samples, peak: volume)
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

    // MARK: Building blocks

    struct Note {
        let start: Double
        let frequency: Double
        let length: Double
    }

    /// Notes with a brassy tone: a few harmonics, quieter as they go up.
    static func chords(_ notes: [Note], seconds: Double, brightness: Double, peak: Float) -> [Float] {
        var samples = [Float](repeating: 0, count: frames(seconds))
        for note in notes {
            let start = frames(note.start)
            for offset in 0..<frames(note.length + 0.4) where start + offset < samples.count {
                let t = time(offset)
                let level = t < 0.015 ? t / 0.015 : exp(-(t - 0.015) / (note.length * 0.6))
                var tone = 0.0
                for harmonic in 1...4 {
                    let strength = pow(brightness * 0.55, Double(harmonic - 1)) / Double(harmonic)
                    tone += sin(2 * .pi * note.frequency * Double(harmonic) * t) * strength
                }
                samples[start + offset] += Float(tone * level)
            }
        }
        return fadeOut(normalized(samples, peak: peak), seconds: 0.3)
    }

    /// Silence while the shell is in the air.
    static func delayed(_ samples: [Float]) -> [Float] {
        [Float](repeating: 0, count: frames(flightTime)) + samples
    }

    static func normalized(_ samples: [Float], peak: Float) -> [Float] {
        let loudest = samples.reduce(0) { max($0, abs($1)) }
        guard loudest > 0 else { return samples }
        let gain = peak / loudest
        return samples.map { $0 * gain }
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
