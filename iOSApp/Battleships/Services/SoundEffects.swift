import AVFoundation

/// Plays the game's synthesised sound effects (see ``SoundSynthesis``). They go through the ambient
/// audio session, so they respect the silent switch and mix with whatever else is playing.
@MainActor
final class SoundEffects: FeedbackPlayer {
    private let isEnabled: @MainActor () -> Bool
    private let engine = AVAudioEngine()
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoice = 0
    private var buffers: [FeedbackEvent: AVAudioPCMBuffer] = [:]
    private var isPrepared = false

    init(isEnabled: @escaping @MainActor () -> Bool) {
        self.isEnabled = isEnabled
    }

    func play(_ event: FeedbackEvent) {
        guard isEnabled() else { return }
        prepareIfNeeded()
        guard let buffer = buffers[event], !voices.isEmpty else { return }
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
    }

    private func prepareIfNeeded() {
        guard !isPrepared else { return }
        isPrepared = true
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        guard let format = AVAudioFormat(standardFormatWithSampleRate: SoundSynthesis.sampleRate, channels: 1) else { return }
        for _ in 0..<5 {
            let voice = AVAudioPlayerNode()
            engine.attach(voice)
            engine.connect(voice, to: engine.mainMixerNode, format: format)
            voices.append(voice)
        }
        for event in FeedbackEvent.allCases {
            let samples = SoundSynthesis.samples(for: event)
            guard !samples.isEmpty,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = buffer.floatChannelData?[0]
            else { continue }
            buffer.frameLength = AVAudioFrameCount(samples.count)
            for (index, sample) in samples.enumerated() {
                channel[index] = sample
            }
            buffers[event] = buffer
        }
    }
}
