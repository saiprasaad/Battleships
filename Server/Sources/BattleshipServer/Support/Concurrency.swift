import Foundation
import NIOConcurrencyHelpers
import Vapor

/// A fair, async-aware mutex.
///
/// Actors alone don't serialize work that suspends (an `await` inside an actor method lets other
/// calls interleave), so every database write that must not race goes through this lock. Nothing
/// that waits on the network may run while it's held: one stalled client would stop every write.
actor AsyncLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    /// When the current holder got the lock, so the health check can spot a holder that never lets go.
    private var heldSince: ContinuousClock.Instant?

    private func acquire() async {
        guard isLocked else {
            isLocked = true
            heldSince = .now
            return
        }
        // Ownership is handed over directly by `release()`, so there is no window for another caller.
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
            heldSince = nil
        } else {
            heldSince = .now
            waiters.removeFirst().resume()
        }
    }

    /// How long the current holder has had the lock, or `nil` when it's free.
    func holdDuration() -> Duration? {
        heldSince.map { .now - $0 }
    }

    nonisolated func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await acquire()
        do {
            let result = try await body()
            await release()
            return result
        } catch {
            await release()
            throw error
        }
    }
}

/// A token-bucket rate limiter keyed by client, account or username.
actor RateLimiter {
    private struct Bucket {
        var tokens: Double
        var updatedAt: Date
    }

    private let capacity: Double
    private let refillPerSecond: Double
    /// Keys are attacker-chosen (usernames, forged addresses), so memory has a ceiling.
    private let maxKeys: Int
    private var buckets: [String: Bucket] = [:]
    private var lastPruned = Date.distantPast

    /// Allows bursts of `limit` and refills to that over `period`.
    init(limit: Int, per period: TimeInterval, maxKeys: Int = 50_000) {
        capacity = Double(max(1, limit))
        refillPerSecond = capacity / period
        self.maxKeys = max(1, maxKeys)
    }

    init(requestsPerMinute: Int) {
        self.init(limit: requestsPerMinute, per: 60)
    }

    /// Takes one request's worth of allowance for `key`; returns `false` when it has none left.
    func consume(_ key: String, now: Date = Date()) -> Bool {
        if now.timeIntervalSince(lastPruned) > 300 {
            pruneRefilled(now)
        }
        var bucket = buckets[key] ?? Bucket(tokens: capacity, updatedAt: now)
        bucket.tokens = min(capacity, bucket.tokens + now.timeIntervalSince(bucket.updatedAt) * refillPerSecond)
        bucket.updatedAt = now
        guard bucket.tokens >= 1 else {
            buckets[key] = bucket
            return false
        }
        bucket.tokens -= 1
        if buckets[key] == nil, buckets.count >= maxKeys {
            makeRoom(now)
        }
        buckets[key] = bucket
        return true
    }

    var trackedKeys: Int { buckets.count }

    /// Forgets buckets that have refilled completely: they behave exactly like a missing one.
    private func pruneRefilled(_ now: Date) {
        lastPruned = now
        let fullAfter = capacity / refillPerSecond
        buckets = buckets.filter { now.timeIntervalSince($0.value.updatedAt) < fullAfter }
    }

    private func makeRoom(_ now: Date) {
        pruneRefilled(now)
        guard buckets.count >= maxKeys else { return }
        // Still full of active keys: drop the least recently used tenth in one go, so a flood of
        // new keys doesn't pay for a sort on every request.
        let excess = buckets.count - maxKeys + max(1, maxKeys / 10)
        for (key, _) in buckets.sorted(by: { $0.value.updatedAt < $1.value.updatedAt }).prefix(excess) {
            buckets[key] = nil
        }
    }
}

/// Runs password hashing on a few threads of its own.
///
/// bcrypt is deliberately slow. On Vapor's shared thread pool, which the SQLite driver also uses, a
/// flood of sign-ins would queue every database query behind it; here a flood only fills a short
/// queue, and requests beyond that are turned away with 429 at once.
final class PasswordHashing: Sendable {
    private let hasher: any PasswordHasher
    private let pool: NIOThreadPool
    private let maxPending: Int
    private let pending = NIOLockedValueBox(0)

    init(hasher: any PasswordHasher, threads: Int, maxPending: Int) {
        self.hasher = hasher
        self.maxPending = max(1, maxPending)
        pool = NIOThreadPool(numberOfThreads: max(1, threads))
        pool.start()
    }

    func hash(_ password: String) async throws -> String {
        try await run { [hasher] in try hasher.hash(password) }
    }

    func verify(_ password: String, created hash: String) async throws -> Bool {
        try await run { [hasher] in try hasher.verify(password, created: hash) }
    }

    /// Jobs running or waiting for a thread.
    var pendingCount: Int {
        pending.withLockedValue { $0 }
    }

    func shutdown() async throws {
        try await pool.shutdownGracefully()
    }

    private func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        let admitted = pending.withLockedValue { count in
            guard count < maxPending else { return false }
            count += 1
            return true
        }
        guard admitted else { throw AppError.serverBusy }
        defer { pending.withLockedValue { $0 -= 1 } }
        return try await pool.runIfActive(work)
    }
}

/// The threads stop with the application.
extension PasswordHashing: LifecycleHandler {
    func shutdownAsync(_ application: Application) async {
        do {
            try await shutdown()
        } catch {
            application.logger.report(error: error)
        }
    }

    func shutdown(_ application: Application) {
        do {
            try pool.syncShutdownGracefully()
        } catch {
            application.logger.report(error: error)
        }
    }
}
