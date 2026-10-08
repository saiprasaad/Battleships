import FluentSQL
import NIOConcurrencyHelpers
import Vapor

/// `GET /health`, for the hosting platform's health checks. Fails with 503 when the database doesn't
/// answer a trivial query within a couple of seconds, or when a single write has held the write
/// lock for a minute: nothing legitimate takes that long, and until it lets go no move can be made.
struct HealthController: RouteCollection {
    let services: AppServices
    var databaseTimeout: Duration = .seconds(2)
    var maxWriteLockHold: Duration = .seconds(60)

    func boot(routes: any RoutesBuilder) throws {
        routes.get("health", use: check)
    }

    @Sendable
    func check(req: Request) async -> Response {
        let problem: String? = if let held = await services.writeLock.holdDuration(), held > maxWriteLockHold {
            "writes stalled"
        } else if let sql = req.db as? any SQLDatabase, await !Self.databaseResponds(sql, within: databaseTimeout) {
            "database unavailable"
        } else {
            nil
        }
        if let problem {
            req.logger.error("Health check failed: \(problem)")
        }
        let response = Response(status: problem == nil ? .ok : .serviceUnavailable)
        try? response.content.encode(["status": problem ?? "ok"])
        return response
    }

    /// Runs `SELECT 1`, giving up after `timeout` even if the query itself never comes back.
    static func databaseResponds(_ sql: any SQLDatabase, within timeout: Duration) async -> Bool {
        await withCheckedContinuation { continuation in
            let answered = NIOLockedValueBox(false)
            let answer: @Sendable (Bool) -> Void = { healthy in
                let first = answered.withLockedValue { done in
                    defer { done = true }
                    return !done
                }
                if first {
                    continuation.resume(returning: healthy)
                }
            }
            let timer = Task {
                try await Task.sleep(for: timeout)
                answer(false)
            }
            Task {
                answer((try? await sql.raw("SELECT 1").run()) != nil)
                timer.cancel()
            }
        }
    }
}
