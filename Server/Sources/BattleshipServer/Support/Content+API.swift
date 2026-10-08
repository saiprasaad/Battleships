import BattleshipAPI
import Vapor

// The wire types live in the shared BattleshipAPI module so the app and server can't drift apart.
// These conformances let route handlers return them directly.
extension Account: @retroactive Content {}
extension AuthResponse: @retroactive Content {}
extension PlayerSummary: @retroactive Content {}
extension LeaderboardEntry: @retroactive Content {}
extension GameSummary: @retroactive Content {}
extension GameDetail: @retroactive Content {}
extension FireResponse: @retroactive Content {}
extension APIErrorBody: @retroactive Content {}
extension Credentials: @retroactive Content {}
extension CreateGameRequest: @retroactive Content {}
extension AcceptChallengeRequest: @retroactive Content {}
extension FireRequest: @retroactive Content {}
extension DeviceRegistration: @retroactive Content {}

extension Request {
    /// Best guess at the caller's IP address, honouring `X-Forwarded-For` from a reverse proxy.
    var clientAddress: String {
        if let forwarded = headers.first(name: "X-Forwarded-For")?.split(separator: ",").first {
            return forwarded.trimmingCharacters(in: .whitespaces)
        }
        return remoteAddress?.ipAddress ?? "unknown"
    }
}

struct RateLimitMiddleware: AsyncMiddleware {
    let limiter: RateLimiter

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard await limiter.consume(request.clientAddress) else {
            throw AppError.rateLimited
        }
        return try await next.respond(to: request)
    }
}

extension Sequence<UInt8> {
    var hexString: String {
        let digits = Array("0123456789abcdef".utf8)
        var characters: [UInt8] = []
        for byte in self {
            characters.append(digits[Int(byte >> 4)])
            characters.append(digits[Int(byte & 0x0F)])
        }
        return String(decoding: characters, as: UTF8.self)
    }
}
