import AVFoundation
import UIKit

/// The sound stage: plays the game's synthesised sound effects (see ``SoundSynthesis``) on one
/// `AVAudioEngine`, a few pre-rendered takes of each so repeats don't sound stamped out, panned to
/// where they happen, scheduled on the host clock when a play carries a delay so a landing meets
/// its frame, and runs the loops and the ambient bed under everything while they're wanted. It all
/// goes through the ambient audio session, so it respects the silent switch and mixes with
/// whatever else is playing.
///
/// Graph: six one-shot voices into a dry mixer, each with a send into a large-hall reverb (fully
/// wet, fed per voice for the splashes and explosions, bypassed in Low Power Mode); seven bed
/// voices (one per ``SoundSynthesis/Loop``, the fire's crackle among them) into a bed mixer whose
/// output volume carries the ducking, the idle fade and the VoiceOver dip; both into the main mixer.
///
/// VoiceOver: the start of an announcement can't be observed from here, only its end
/// (`UIAccessibility.announcementDidFinishNotification`), so instead of ducking per announcement
/// the bed and the loops sit 10 dB lower for as long as VoiceOver runs.
@MainActor
final class SoundEffects: FeedbackPlayer {
    // MARK: Tuning

    /// The engine rests this long after the last one-shot ends, if no loop or bed runs.
    private static let idleTime: TimeInterval = 5
    private static let voiceCount = 6
    /// Scene changes fade each bed voice over this long.
    private static let sceneFade = 0.8
    private static let loopFadeIn = 0.4
    private static let loopFadeOut = 0.6
    private static let idleFadeOut = 3.0
    private static let idleFadeIn = 1.5
    private static let fadeSteps = 16
    /// The fire's crackle, relative to the effects.
    private static let loopLevel = decibels(-18)
    /// The bed under VoiceOver.
    private static let voiceOverDip = decibels(-10)
    /// How long the defeat's rain runs.
    private static let rainRun: TimeInterval = 12

    private let isEnabled: @MainActor () -> Bool
    private let ambientEnabled: @MainActor () -> Bool
    private let format = AVAudioFormat(standardFormatWithSampleRate: SoundSynthesis.sampleRate, channels: 1)

    // MARK: The graph

    private struct Graph {
        let dry: AVAudioMixerNode
        let send: AVAudioMixerNode?
        let reverb: AVAudioUnitReverb?
        let bed: AVAudioMixerNode
    }

    /// A one-shot voice: its node, what it is playing, and when that ends.
    private struct Voice {
        let node: AVAudioPlayerNode
        let dryBus: AVAudioNodeBus
        let sendBus: AVAudioNodeBus?
        var priority = 0
        /// System uptime when its sound is over; a free voice has one in the past.
        var endsAt: TimeInterval = 0
    }

    /// A looping voice of the bed (or the fire): its node and the level the scene wants.
    private final class BedVoice {
        let node: AVAudioPlayerNode
        var target: Float = 0
        var fade: Task<Void, Never>?

        init(node: AVAudioPlayerNode) {
            self.node = node
        }
    }

    private var engine = AVAudioEngine()
    private var graph: Graph?
    private var voices: [Voice] = []
    private var beds: [SoundSynthesis.Loop: BedVoice] = [:]

    // MARK: Sounds

    /// The takes of each sound, by event, in take order (a slot is empty until it is synthesised).
    private var buffers: [FeedbackEvent: [AVAudioPCMBuffer?]] = [:]
    private var slowBuffers: [FeedbackEvent: AVAudioPCMBuffer] = [:]
    private var loopBuffers: [SoundSynthesis.Loop: AVAudioPCMBuffer] = [:]
    private var shuffleBuffers: [Int: AVAudioPCMBuffer] = [:]
    private var nextTake: [FeedbackEvent: Int] = [:]

    // MARK: State

    private var scene: AmbientScene = .none
    private var loopsOn: Set<FeedbackEvent> = []
    /// `rest()` was called and nothing has asked for sound since.
    private var isResting = false
    private var isInterrupted = false
    private var isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    /// The bed faded out after `Timing.ambientIdleFade` without interaction; the next play brings it back.
    private var isIdleSilenced = false
    private var duckGain: Float = 1
    private var idleGain: Float = 1
    private var duckTask: Task<Void, Never>?
    private var idleFadeTask: Task<Void, Never>?
    private var idleGainTask: Task<Void, Never>?
    private var rainTask: Task<Void, Never>?
    private var idleTimer: Task<Void, Never>?
    private var observers: [any NSObjectProtocol] = []

    init(isEnabled: @escaping @MainActor () -> Bool, ambientEnabled: @escaping @MainActor () -> Bool) {
        self.isEnabled = isEnabled
        self.ambientEnabled = ambientEnabled
        // Synthesising every sound takes a moment, so it happens in the background at launch,
        // installing each take as it finishes (the shots first) and the loops after the effects.
        // Until a sound is installed, its event simply plays nothing.
        Task.detached(priority: .utility) { [weak self] in
            SoundSynthesis.allSamples { event, variant, samples in
                Task { @MainActor in self?.install(event, variant: variant, samples: samples) }
            }
            for event in SoundSynthesis.slowEvents {
                if let samples = SoundSynthesis.slowSamples(for: event) {
                    await self?.installSlow(event, samples: samples)
                }
            }
            for loop in SoundSynthesis.Loop.allCases {
                let samples = SoundSynthesis.loop(loop)
                await self?.install(loop, samples: samples)
            }
        }
        observeTheSystem()
    }

    // MARK: FeedbackPlayer

    func play(_ event: FeedbackEvent) {
        play(event, variation: .default)
    }

    /// Plays `event`: the take `variation.seed` picks (or the next in turn), from `variation.pan`,
    /// at `variation.intensity` with a little level jitter, after `variation.delay` on the host
    /// clock, the slow take when `variation.isFinal`, on a voice no more important sound is using.
    func play(_ event: FeedbackEvent, variation: FeedbackVariation) {
        noteInteraction()
        guard isEnabled(), event != .burning else { return }
        guard let buffer = buffer(for: event, variation: variation) else { return }
        guard prepareEngine(), startEngine() else { return }
        isResting = false
        let priority = Self.priority(of: event)
        guard let index = voiceIndex(for: priority) else { return }
        let voice = voices[index]
        voice.node.stop()
        voice.node.pan = Float(min(1, max(-1, variation.pan)))
        let level = Float(min(1, max(0, variation.intensity))) * jitter(seed: variation.seed)
        setLevel(level, send: Self.reverbSend(for: event, variation: variation), of: voice)
        let when: AVAudioTime? = variation.delay > 0
            ? AVAudioTime(hostTime: mach_absolute_time() + AVAudioTime.hostTime(forSeconds: variation.delay))
            : nil
        voice.node.scheduleBuffer(buffer, at: when, options: [], completionHandler: nil)
        voice.node.play()
        let seconds = Double(buffer.frameLength) / buffer.format.sampleRate
        voices[index].priority = priority
        voices[index].endsAt = ProcessInfo.processInfo.systemUptime + max(0, variation.delay) + seconds
        duck(for: event, after: max(0, variation.delay))
        restIfIdle()
    }

    /// Starts the engine early, so the first shot has no latency, and brings the bed back.
    func prepare() {
        isResting = false
        guard isEnabled(), prepareEngine(), startEngine() else { return }
        applyScene()
        applyLoops()
    }

    /// The screen is gone, or the app is in the background: loops and the bed fade out and the
    /// engine rests once the last sound has played.
    func rest() {
        isResting = true
        duckTask?.cancel()
        idleFadeTask?.cancel()
        rainTask?.cancel()
        applyScene()
        applyLoops()
        restIfIdle()
    }

    /// `.burning` loops the fire's crackle at −18 dB while any own ship burns; other events are not loops.
    func setLoop(_ event: FeedbackEvent, isOn: Bool) {
        guard event == .burning else { return }
        if isOn {
            loopsOn.insert(event)
            isResting = false
        } else {
            loopsOn.remove(event)
        }
        applyLoops()
    }

    /// Moves the bed to `scene`'s layers with 0.8 s fades; `.none` fades them all out.
    func setAmbientScene(_ scene: AmbientScene) {
        self.scene = scene
        if scene != .none {
            isResting = false
        }
        applyScene()
    }

    // MARK: Installing sounds

    private func install(_ event: FeedbackEvent, variant: Int, samples: [Float]) {
        guard let format, let buffer = Self.makeBuffer(samples, format: format) else { return }
        var takes = buffers[event] ?? [AVAudioPCMBuffer?](repeating: nil, count: SoundSynthesis.variantCount(for: event))
        if variant < takes.count {
            takes[variant] = buffer
        } else {
            takes.append(buffer)
        }
        buffers[event] = takes
    }

    private func installSlow(_ event: FeedbackEvent, samples: [Float]) {
        guard let format, let buffer = Self.makeBuffer(samples, format: format) else { return }
        slowBuffers[event] = buffer
    }

    private func install(_ loop: SoundSynthesis.Loop, samples: [Float]) {
        guard let format, let buffer = Self.makeBuffer(samples, format: format) else { return }
        loopBuffers[loop] = buffer
        // The bed starts as its loops become ready.
        if loop == .burning {
            applyLoops()
        } else {
            applyScene()
        }
    }

    private nonisolated static func makeBuffer(_ samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        return buffer
    }

    /// The buffer a play of `event` uses: the slow take for the finale, the shuffle sweep for its
    /// ship count, the take `seed` picks for the shots, the direction for the last-ship sting, and
    /// otherwise the takes in turn.
    private func buffer(for event: FeedbackEvent, variation: FeedbackVariation) -> AVAudioPCMBuffer? {
        if variation.isFinal, let slow = slowBuffers[event] {
            return slow
        }
        if event == .shuffle {
            return shuffleBuffer(count: variation.count)
        }
        let takes = (buffers[event] ?? []).compactMap { $0 }
        guard !takes.isEmpty else { return nil }
        let index: Int
        if event == .lastShip {
            index = variation.isMine ? 1 : 0
        } else if variation.seed != 0 {
            index = Int(variation.seed.magnitude % UInt(takes.count))
        } else {
            index = nextTake[event, default: 0] % takes.count
            nextTake[event] = (index + 1) % takes.count
        }
        return takes[min(index, takes.count - 1)]
    }

    private func shuffleBuffer(count: Int) -> AVAudioPCMBuffer? {
        let clicks = min(max(count, 1), Timing.Stagger.maxItems)
        if let buffer = shuffleBuffers[clicks] {
            return buffer
        }
        guard let format, let buffer = Self.makeBuffer(SoundSynthesis.shuffleSweep(count: clicks), format: format) else { return nil }
        shuffleBuffers[clicks] = buffer
        return buffer
    }

    // MARK: Voices

    /// How much a sound matters when voices run out: a sinking or the ceremony is never cut by a
    /// click, and a hit is never cut by a splash.
    private static func priority(of event: FeedbackEvent) -> Int {
        switch event {
        case .sunk, .sunkOwn, .victory, .defeat, .finalBlow: 3
        case .hit, .hitOwn: 2
        default: 1
        }
    }

    /// How much of a sound goes to the hall: the splashes and explosions carry a short tail.
    private static func reverbSend(for event: FeedbackEvent, variation: FeedbackVariation) -> Float {
        switch event {
        case .miss, .nearMiss, .hit, .hitOwn: 0.25
        case .sunk, .sunkOwn: variation.isFinal ? 0.35 : 0.3
        case .finalBlow: 0.35
        default: 0
        }
    }

    /// A free voice, or else the oldest voice playing something no more important than
    /// `priority`; `nil` when every voice holds something that must not be cut.
    private func voiceIndex(for priority: Int) -> Int? {
        let now = ProcessInfo.processInfo.systemUptime
        if let free = voices.indices.first(where: { voices[$0].endsAt <= now }) {
            return free
        }
        let candidates = voices.indices.filter { voices[$0].priority <= priority }
        return candidates.min { (voices[$0].priority, voices[$0].endsAt) < (voices[$1].priority, voices[$1].endsAt) }
    }

    /// ±1.5 dB of level jitter, fixed by `seed` or drawn afresh when there is none.
    private func jitter(seed: Int) -> Float {
        guard seed != 0 else { return Float.random(in: 0.85...1) }
        var state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15
        state ^= state >> 29
        state = state &* 0xBF58_476D_1CE4_E5B9
        return 0.85 + 0.15 * Float(state % 1_000) / 1_000
    }

    /// Sets a voice's dry level and its send into the hall, per connection so one never overwrites the other.
    private func setLevel(_ level: Float, send: Float, of voice: Voice) {
        guard let graph else { return }
        if let dry = voice.node.destination(forMixer: graph.dry, bus: voice.dryBus) {
            dry.volume = level
        } else {
            voice.node.volume = level
        }
        if let sendMixer = graph.send, let sendBus = voice.sendBus,
           let wet = voice.node.destination(forMixer: sendMixer, bus: sendBus) {
            wet.volume = level * send
        }
    }

    // MARK: Ducking

    /// Shots and landings duck the bed 6 dB with a 400 ms recovery; the fanfare and the lament
    /// duck it 10 dB for 2.5 s. A later duck takes over from an earlier one.
    private func duck(for event: FeedbackEvent, after delay: TimeInterval) {
        let depth: Float
        let hold: TimeInterval
        let recovery: TimeInterval
        switch event {
        case .fire, .hit, .hitOwn, .nearMiss, .sunk, .sunkOwn, .finalBlow:
            depth = Self.decibels(-6)
            hold = 0.1
            recovery = 0.4
        case .victory, .defeat:
            depth = Self.decibels(-10)
            hold = 2.5
            recovery = 0.8
        default:
            return
        }
        guard isBedRunning else { return }
        duckTask?.cancel()
        let steps = Self.fadeSteps
        duckTask = Task { [weak self] in
            do {
                if delay > 0 {
                    try await Task.sleep(for: .seconds(delay))
                }
                guard let self else { return }
                self.duckGain = depth
                self.applyBedGain()
                try await Task.sleep(for: .seconds(hold))
                for step in 1...steps {
                    try await Task.sleep(for: .seconds(recovery / Double(steps)))
                    self.duckGain = depth + (1 - depth) * Float(step) / Float(steps)
                    self.applyBedGain()
                }
            } catch {
                // Cancelled: a newer duck has taken over.
            }
        }
    }

    private func applyBedGain() {
        guard let graph else { return }
        let dip: Float = UIAccessibility.isVoiceOverRunning ? Self.voiceOverDip : 1
        graph.bed.outputVolume = duckGain * idleGain * dip
    }

    // MARK: The bed

    /// The layers of each scene, as levels relative to the effects.
    private static func levels(for scene: AmbientScene) -> [SoundSynthesis.Loop: Float] {
        switch scene {
        case .none:
            return [:]
        case .welcome, .lobby:
            return [.wind: decibels(-18), .swell: decibels(-20)]
        case .placement:
            return [.wind: decibels(-20), .swell: decibels(-22), .hum: decibels(-18)]
        case let .battle(mood):
            switch mood {
            case .ready:
                return [.hum: decibels(-18), .sonarRoom: decibels(-24), .wind: decibels(-24)]
            case .danger:
                // INCOMING: the hum comes up 4 dB and the tension drone fades in; the wind stays low.
                return [.hum: decibels(-14), .tension: decibels(-18), .wind: decibels(-24)]
            case .triumph:
                return levels(for: .gameOver(didWin: true))
            case .defeat:
                return levels(for: .gameOver(didWin: false))
            default:
                return [.hum: decibels(-18), .wind: decibels(-22)]
            }
        case let .gameOver(didWin):
            return didWin
                ? [.wind: decibels(-18), .swell: decibels(-20)]
                : [.wind: decibels(-22), .rain: decibels(-18)]
        }
    }

    /// Whether the bed may play at all right now.
    private var bedAllowed: Bool {
        isEnabled() && ambientEnabled() && !isResting && !isInterrupted && !isLowPower && !isIdleSilenced
            && !AVAudioSession.sharedInstance().isOtherAudioPlaying
    }

    private var isBedRunning: Bool {
        beds.values.contains { $0.node.isPlaying }
    }

    /// Moves every bed voice to what the scene wants, with the scene fade.
    private func applyScene() {
        let levels = bedAllowed ? Self.levels(for: scene) : [:]
        for loop in SoundSynthesis.Loop.allCases where loop != .burning {
            setBed(loop, to: levels[loop] ?? 0, over: Self.sceneFade)
        }
        if levels[.rain] != nil {
            if rainTask == nil {
                rainTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Self.rainRun))
                    guard !Task.isCancelled, let self else { return }
                    self.rainTask = nil
                    self.setBed(.rain, to: 0, over: 2)
                }
            }
        } else {
            rainTask?.cancel()
            rainTask = nil
        }
        if isBedRunning {
            scheduleIdleFade()
        }
    }

    /// Starts or stops the fire's crackle.
    private func applyLoops() {
        let wantsFire = loopsOn.contains(.burning) && isEnabled() && !isResting && !isInterrupted
        setBed(.burning, to: wantsFire ? Self.loopLevel : 0, over: wantsFire ? Self.loopFadeIn : Self.loopFadeOut)
    }

    /// Fades `loop`'s voice to `target`, starting it if it was silent and stopping it after a fade to 0.
    private func setBed(_ loop: SoundSynthesis.Loop, to target: Float, over seconds: Double) {
        guard let voice = beds[loop] ?? makeBedVoice(loop) else { return }
        voice.target = target
        if target > 0 {
            guard let buffer = loopBuffers[loop], prepareEngine(), startEngine() else { return }
            if !voice.node.isPlaying {
                voice.node.volume = 0
                voice.node.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
                voice.node.play()
            }
            idleTimer?.cancel()
            applyBedGain()
            fade(loop, to: target, over: seconds, stoppingAfter: false)
        } else if voice.node.isPlaying {
            fade(loop, to: 0, over: seconds, stoppingAfter: true)
        } else {
            voice.fade?.cancel()
        }
    }

    private func makeBedVoice(_ loop: SoundSynthesis.Loop) -> BedVoice? {
        guard prepareEngine(), let voice = beds[loop] else { return nil }
        return voice
    }

    /// Ramps a bed voice's volume to `target` in a few steps over `seconds`, then stops it if asked.
    private func fade(_ loop: SoundSynthesis.Loop, to target: Float, over seconds: Double, stoppingAfter stops: Bool) {
        guard let voice = beds[loop] else { return }
        voice.fade?.cancel()
        let start = voice.node.volume
        let steps = Self.fadeSteps
        voice.fade = Task { [weak self] in
            for step in 1...steps {
                do {
                    try await Task.sleep(for: .seconds(seconds / Double(steps)))
                } catch {
                    return
                }
                guard let self, let voice = self.beds[loop] else { return }
                voice.node.volume = start + (target - start) * Float(step) / Float(steps)
            }
            guard stops, let self, let voice = self.beds[loop], voice.target == 0 else { return }
            voice.node.stop()
            self.restIfIdle()
        }
    }

    // MARK: Idle

    /// Every play is an interaction: the idle fade starts over, and a bed that had faded out comes back.
    private func noteInteraction() {
        if isIdleSilenced {
            isIdleSilenced = false
            idleGainTask?.cancel()
            idleGain = 0
            applyScene()
            rampIdleGain(to: 1, over: Self.idleFadeIn)
        } else {
            scheduleIdleFade()
        }
    }

    /// After `Timing.ambientIdleFade` without interaction the bed fades out and stops.
    private func scheduleIdleFade() {
        idleFadeTask?.cancel()
        guard isBedRunning else { return }
        idleFadeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Timing.ambientIdleFade))
            guard !Task.isCancelled, let self, self.isBedRunning else { return }
            self.rampIdleGain(to: 0, over: Self.idleFadeOut)
        }
    }

    private func rampIdleGain(to target: Float, over seconds: Double) {
        idleGainTask?.cancel()
        let start = idleGain
        let steps = Self.fadeSteps
        idleGainTask = Task { [weak self] in
            for step in 1...steps {
                do {
                    try await Task.sleep(for: .seconds(seconds / Double(steps)))
                } catch {
                    return
                }
                guard let self else { return }
                self.idleGain = start + (target - start) * Float(step) / Float(steps)
                self.applyBedGain()
            }
            guard let self, target == 0 else { return }
            self.isIdleSilenced = true
            self.applyScene()
        }
    }

    // MARK: The engine

    /// Sets up the audio session and the graph the first time a sound plays.
    private func prepareEngine() -> Bool {
        if graph != nil { return true }
        guard format != nil else { return false }
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        buildGraph(withReverb: true)
        return true
    }

    private func buildGraph(withReverb: Bool) {
        guard let format else { return }
        let dry = AVAudioMixerNode()
        let bed = AVAudioMixerNode()
        engine.attach(dry)
        engine.attach(bed)
        engine.connect(dry, to: engine.mainMixerNode, format: format)
        engine.connect(bed, to: engine.mainMixerNode, format: format)
        var send: AVAudioMixerNode?
        var reverb: AVAudioUnitReverb?
        if withReverb {
            let sendMixer = AVAudioMixerNode()
            let hall = AVAudioUnitReverb()
            hall.loadFactoryPreset(.largeHall)
            hall.wetDryMix = 100
            engine.attach(sendMixer)
            engine.attach(hall)
            engine.connect(sendMixer, to: hall, format: format)
            engine.connect(hall, to: engine.mainMixerNode, format: format)
            send = sendMixer
            reverb = hall
        }
        voices = (0..<Self.voiceCount).map { _ in
            let node = AVAudioPlayerNode()
            engine.attach(node)
            let dryBus = dry.nextAvailableInputBus
            if let send {
                let sendBus = send.nextAvailableInputBus
                engine.connect(
                    node,
                    to: [AVAudioConnectionPoint(node: dry, bus: dryBus), AVAudioConnectionPoint(node: send, bus: sendBus)],
                    fromBus: 0,
                    format: format
                )
                return Voice(node: node, dryBus: dryBus, sendBus: sendBus)
            }
            engine.connect(node, to: dry, format: format)
            return Voice(node: node, dryBus: dryBus, sendBus: nil)
        }
        beds = [:]
        for loop in SoundSynthesis.Loop.allCases {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: bed, format: format)
            node.volume = 0
            beds[loop] = BedVoice(node: node)
        }
        graph = Graph(dry: dry, send: send, reverb: reverb, bed: bed)
        applyLowPower()
        applyBedGain()
    }

    private func startEngine() -> Bool {
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            guard graph?.reverb != nil else { return false }
            // If the hall is what the engine objects to, the plain graph still plays.
            rebuildEngine(withReverb: false)
            return (try? engine.start()) != nil
        }
    }

    /// A new engine and graph (after a media services reset, or to drop the reverb), with the bed
    /// and the loops started again as wanted.
    private func rebuildEngine(withReverb: Bool) {
        idleTimer?.cancel()
        for voice in beds.values {
            voice.fade?.cancel()
        }
        engine = AVAudioEngine()
        graph = nil
        voices = []
        beds = [:]
        nextTake = [:]
        buildGraph(withReverb: withReverb)
        applyScene()
        applyLoops()
    }

    /// Pauses the engine once the last sound has had time to finish, so it isn't kept running
    /// (and rendering silence) for the rest of the session or in the background. Not while a loop
    /// or the bed plays: that is the engine's job then.
    private func restIfIdle() {
        idleTimer?.cancel()
        guard !isBedRunning else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let busyUntil = voices.map(\.endsAt).max() ?? now
        let wait = max(0, busyUntil - now) + Self.idleTime
        idleTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self, !self.isBedRunning else { return }
            let again = ProcessInfo.processInfo.systemUptime
            guard self.voices.allSatisfy({ $0.endsAt <= again }) else { return }
            self.engine.pause()
        }
    }

    private func applyLowPower() {
        graph?.reverb?.bypass = isLowPower
    }

    // MARK: The system

    private func observeTheSystem() {
        let center = NotificationCenter.default
        // If the system's media services restart, the engine is gone; build a new one.
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildEngine(withReverb: true) }
        })
        // A call or another app's audio: loops and the bed stop, and come back if the system says so.
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated { self?.handleInterruption(typeRaw: type, optionsRaw: options) }
        })
        // Another app starting or stopping its audio: the bed yields to it.
        observers.append(center.addObserver(forName: AVAudioSession.silenceSecondaryAudioHintNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyScene() }
        })
        observers.append(center.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.powerStateDidChange() }
        })
        observers.append(center.addObserver(forName: UIAccessibility.voiceOverStatusDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyBedGain() }
        })
        observers.append(center.addObserver(forName: UIAccessibility.announcementDidFinishNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyBedGain() }
        })
    }

    private func handleInterruption(typeRaw: UInt?, optionsRaw: UInt?) {
        guard let typeRaw, let type = AVAudioSession.InterruptionType(rawValue: typeRaw) else { return }
        switch type {
        case .began:
            isInterrupted = true
            duckTask?.cancel()
            for voice in beds.values {
                voice.fade?.cancel()
                voice.node.stop()
                voice.node.volume = 0
            }
            engine.pause()
        case .ended:
            isInterrupted = false
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw ?? 0)
            if options.contains(.shouldResume) {
                applyScene()
                applyLoops()
            }
        @unknown default:
            break
        }
    }

    private func powerStateDidChange() {
        isLowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        applyLowPower()
        applyScene()
    }

    private static func decibels(_ value: Double) -> Float {
        Float(pow(10, value / 20))
    }
}
