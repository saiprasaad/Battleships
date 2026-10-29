import Foundation

/// Notes every stretch during which the main thread was too busy to serve its queue: a background
/// thread posts a probe to the main queue every `period` seconds, and a probe served `threshold` or
/// more late records a stall from when it was sent until it ran. Running through a filmstrip, it
/// says whether what CI's recording shows is the app's motion or the main thread standing still.
final class MainThreadWatchdog: @unchecked Sendable {
    struct Stall: Sendable {
        let start: Date
        let length: TimeInterval
    }

    let threshold: TimeInterval
    private let lock = NSLock()
    private var isRunning = true
    private var stalls: [Stall] = []
    /// The end of the last stall recorded: probes sent while it lasted are part of it, not new ones.
    private var coveredUntil = Date.distantPast

    init(threshold: TimeInterval = 0.1, period: TimeInterval = 0.04) {
        self.threshold = threshold
        let thread = Thread { [weak self] in
            while let self, self.running {
                let sent = Date()
                DispatchQueue.main.async { [weak self] in
                    self?.serve(sentAt: sent)
                }
                Thread.sleep(forTimeInterval: period)
            }
        }
        thread.name = "MainThreadWatchdog"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    private var running: Bool {
        lock.withLock { isRunning }
    }

    private func serve(sentAt sent: Date) {
        let served = Date()
        let latency = served.timeIntervalSince(sent)
        lock.withLock {
            guard latency >= threshold, sent >= coveredUntil else { return }
            stalls.append(Stall(start: sent, length: latency))
            coveredUntil = served
        }
    }

    /// Stops probing and returns the stalls seen, oldest first.
    func stop() -> [Stall] {
        lock.withLock {
            isRunning = false
            return stalls
        }
    }

    /// The stalls as one line for the timeline: each as its start relative to `origin` and its
    /// length, e.g. `+0.12s:0.43s`, or `none`.
    static func describe(_ stalls: [Stall], from origin: Date) -> String {
        guard !stalls.isEmpty else { return "none" }
        return stalls.map { String(format: "%+.2fs:%.2fs", $0.start.timeIntervalSince(origin), $0.length) }.joined(separator: ",")
    }
}
