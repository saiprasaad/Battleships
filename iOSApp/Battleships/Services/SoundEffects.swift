import AVFoundation

/// Plays the game's synthesised sound effects (see ``SoundSynthesis``). They go through the ambient
/// audio session, so they respect the silent switch and mix with whatever else is playing.
@MainActor
final class SoundEffects: FeedbackPlayer {
    /// The engine rests after this long without a sound, rather than rendering silence.
    private static let idleTime: Duration = .seconds(5)

    private let isEnabled: @MainActor () -> Bool
    private let format = AVAudioFormat(standardFormatWithSampleRate: SoundSynthesis.sampleRate, channels: 1)
    private var engine = AVAudioEngine()
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoice = 0
    private var buffers: [FeedbackEvent: AVAudioPCMBuffer] = [:]
    private var idleTimer: Task<Void, Never>?
    private var resetObserver: (any NSObjectProtocol)?

    init(isEnabled: @escaping @MainActor () -> Bool) {
        self.isEnabled = isEnabled
        // Synthesising every sound takes a moment, so it happens in the background at launch.
        // Until it's done, events simply play no sound.
        Task.detached(priority: .utility) { [weak self] in
            let samples = SoundSynthesis.allSamples()
            await self?.install(samples)
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
        guard isEnabled(), let buffer = buffers[event], prepareEngine() else { return }
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                return
            }
        }
        // A few voices in turn, so a gun can still be booming when its shell lands.
        let voice = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        voice.stop()
        voice.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        voice.play()
        restIfIdle()
    }

    private func install(_ samples: [FeedbackEvent: [Float]]) {
        guard let format else { return }
        for (event, samples) in samples {
            guard !samples.isEmpty,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0]
            else { continue }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            samples.withUnsafeBufferPointer { source in
                channel.update(from: source.baseAddress!, count: samples.count)
            }
            buffers[event] = buffer
        }
    }

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

    private func rebuildEngine() {
        idleTimer?.cancel()
        engine = AVAudioEngine()
        voices = []
        nextVoice = 0
    }

    /// Pauses the engine once the last sound has had time to finish, so it isn't kept running
    /// (and rendering silence) for the rest of the session or in the background.
    private func restIfIdle() {
        idleTimer?.cancel()
        idleTimer = Task { [weak self] in
            do {
                try await Task.sleep(for: Self.idleTime)
            } catch {
                return
            }
            self?.engine.pause()
        }
    }
}
