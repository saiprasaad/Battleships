import Foundation

/// A fair, async-aware mutex.
///
/// Actors alone don't serialize work that suspends (an `await` inside an actor method lets other
/// calls interleave), so every database write that must not race goes through this lock.
actor AsyncLock {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    private func acquire() async {
        guard isLocked else {
            isLocked = true
            return
        }
        // Ownership is handed over directly by `release()`, so there is no window for another caller.
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isLocked = false
        } else {
            waiters.removeFirst().resume()
        }
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

/// A token-bucket rate limiter keyed by client.
actor RateLimiter {
    private struct Bucket {
        var tokens: Double
        var updatedAt: Date
    }

    private let capacity: Double
    private let refillPerSecond: Double
    private var buckets: [String: Bucket] = [:]
    private var lastPruned = Date.distantPast

    init(requestsPerMinute: Int) {
        capacity = Double(max(1, requestsPerMinute))
        refillPerSecond = capacity / 60
    }

    /// Takes one request's worth of allowance for `key`; returns `false` when it has none left.
    func consume(_ key: String, now: Date = Date()) -> Bool {
        prune(now)
        var bucket = buckets[key] ?? Bucket(tokens: capacity, updatedAt: now)
        bucket.tokens = min(capacity, bucket.tokens + now.timeIntervalSince(bucket.updatedAt) * refillPerSecond)
        bucket.updatedAt = now
        defer { buckets[key] = bucket }
        guard bucket.tokens >= 1 else { return false }
        bucket.tokens -= 1
        return true
    }

    private func prune(_ now: Date) {
        guard now.timeIntervalSince(lastPruned) > 300 else { return }
        lastPruned = now
        let fullAfter = capacity / refillPerSecond
        buckets = buckets.filter { now.timeIntervalSince($0.value.updatedAt) < fullAfter }
    }
}
