import AVFoundation

/// The sound stage: plays the game's synthesised sound effects (see ``SoundSynthesis``), a few
/// takes of each in turn so repeats don't sound stamped out, panned to where they happen, and loops
/// the ambient bed under everything while it's wanted. They go through the ambient audio session,
/// so they respect the silent switch and mix with whatever else is playing.
@MainActor
final class SoundEffects: FeedbackPlayer {
    /// The engine rests after this long without a sound, rather than rendering silence.
    private static let idleTime: Duration = .seconds(5)
    private static let ambienceFadeIn = 1.5
    private static let ambienceFadeOut = 1.0
    private static let fadeSteps = 20

    private let isEnabled: @MainActor () -> Bool
    private let format = AVAudioFormat(standardFormatWithSampleRate: SoundSynthesis.sampleRate, channels: 1)
    private var engine = AVAudioEngine()
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoice = 0
    /// The takes of each sound, played in turn.
    private var buffers: [FeedbackEvent: [AVAudioPCMBuffer]] = [:]
    private var nextTake: [FeedbackEvent: Int] = [:]
    private var bed: AVAudioPCMBuffer?
    private var bedVoice: AVAudioPlayerNode?
    /// Whether the app wants the bed playing; it may still be loading, or fading out.
    private var wantsAmbience = false
    private var bedFade: Task<Void, Never>?
    private var idleTimer: Task<Void, Never>?
    private var resetObserver: (any NSObjectProtocol)?

    init(isEnabled: @escaping @MainActor () -> Bool) {
        self.isEnabled = isEnabled
        // Synthesising every sound takes a moment, so it happens in the background at launch.
        // Until it's done, events simply play no sound.
        Task.detached(priority: .utility) { [weak self] in
            let takes = SoundSynthesis.allVariants()
            let bed = SoundSynthesis.ambientBed()
            await self?.install(takes, bed: bed)
        }
        // If the system's media services restart, the engine is gone; build a new one.
        resetObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildEngine() }
        }
    }

    func play(_ event: FeedbackEvent) {
        play(event, pan: 0)
    }

    /// Plays `event` from `pan` (−1 left … 1 right), e.g. from where the shell landed on the board.
    func play(_ event: FeedbackEvent, pan: Float) {
        guard isEnabled(), let takes = buffers[event], !takes.isEmpty, prepareEngine(), startEngine() else { return }
        let take = nextTake[event, default: 0] % takes.count
        nextTake[event] = (take + 1) % takes.count
        // A few voices in turn, so a gun can still be booming when its shell lands.
        let voice = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        voice.stop()
        voice.pan = min(1, max(-1, pan))
        voice.scheduleBuffer(takes[take], at: nil, options: [], completionHandler: nil)
        voice.play()
        restIfIdle()
    }

    /// Fades the ambient bed in over 1.5 s, or out over 1 s and then stops it so the engine can rest.
    func setAmbience(_ isOn: Bool) {
        wantsAmbience = isOn
        if isOn {
            startBed()
        } else {
            stopBed()
        }
    }

    private func install(_ takes: [FeedbackEvent: [[Float]]], bed samples: [Float]) {
        guard let format else { return }
        for (event, variants) in takes {
            let made = variants.compactMap { Self.makeBuffer($0, format: format) }
            if !made.isEmpty {
                buffers[event] = made
            }
        }
        bed = Self.makeBuffer(samples, format: format)
        if wantsAmbience {
            startBed()
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

    // MARK: The ambient bed

    private func startBed() {
        guard wantsAmbience, isEnabled(), let bed, let format, prepareEngine(), startEngine() else { return }
        // The engine mustn't rest while the bed plays.
        idleTimer?.cancel()
        let voice: AVAudioPlayerNode
        if let bedVoice {
            voice = bedVoice
        } else {
            voice = AVAudioPlayerNode()
            engine.attach(voice)
            engine.connect(voice, to: engine.mainMixerNode, format: format)
            bedVoice = voice
        }
        if !voice.isPlaying {
            voice.volume = 0
            voice.scheduleBuffer(bed, at: nil, options: .loops, completionHandler: nil)
            voice.play()
        }
        fadeBed(to: 1, over: Self.ambienceFadeIn, stoppingAfter: false)
    }

    private func stopBed() {
        guard let bedVoice, bedVoice.isPlaying else {
            bedFade?.cancel()
            return
        }
        fadeBed(to: 0, over: Self.ambienceFadeOut, stoppingAfter: true)
    }

    /// Ramps the bed's volume to `target` in a few steps over `seconds`, then stops it if asked.
    private func fadeBed(to target: Float, over seconds: Double, stoppingAfter stops: Bool) {
        bedFade?.cancel()
        guard let bedVoice else { return }
        let start = bedVoice.volume
        let steps = Self.fadeSteps
        bedFade = Task { [weak self] in
            for step in 1...steps {
                do {
                    try await Task.sleep(for: .seconds(seconds / Double(steps)))
                } catch {
                    return
                }
                guard let self, let voice = self.bedVoice else { return }
                voice.volume = start + (target - start) * Float(step) / Float(steps)
            }
            guard stops, let self, let voice = self.bedVoice else { return }
            voice.stop()
            self.restIfIdle()
        }
    }

    // MARK: The engine

    /// Sets up the audio session and the engine's voices the first time a sound plays.
    private func prepareEngine() -> Bool {
        guard voices.isEmpty else { return true }
        guard let format else { return false }
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        for _ in 0..<5 {
            let voice = AVAudioPlayerNode()
            engine.attach(voice)
            engine.connect(voice, to: engine.mainMixerNode, format: format)
            voices.append(voice)
        }
        return true
    }

    private func startEngine() -> Bool {
        if engine.isRunning { return true }
        do {
            try engine.start()
            return true
        } catch {
            return false
        }
    }

    private func rebuildEngine() {
        idleTimer?.cancel()
        bedFade?.cancel()
        engine = AVAudioEngine()
        voices = []
        nextVoice = 0
        bedVoice = nil
        if wantsAmbience {
            startBed()
        }
    }

    /// Pauses the engine once the last sound has had time to finish, so it isn't kept running
    /// (and rendering silence) for the rest of the session or in the background. Not while the
    /// bed is playing: that is the engine's job then.
    private func restIfIdle() {
        idleTimer?.cancel()
        guard bedVoice?.isPlaying != true else { return }
        idleTimer = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.idleTime)
            } catch {
                return
            }
            guard let self, self.bedVoice?.isPlaying != true else { return }
            self.engine.pause()
        }
    }
}
