import BattleshipAPI
import NIOConcurrencyHelpers
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
extension ReportPlayerRequest: @retroactive Content {}
extension AuthProviders: @retroactive Content {}
extension AppleSignInRequest: @retroactive Content {}
extension GoogleSignInRequest: @retroactive Content {}
extension ExternalSignInResponse: @retroactive Content {}
extension CompleteSignupRequest: @retroactive Content {}

extension Request {
    /// The address rate limits are keyed by. Forwarding headers are only believed when the operator
    /// says a proxy sets them: any client can send its own `X-Forwarded-For`.
    func clientAddress(from source: ServerSettings.ClientAddressSource) -> String {
        switch source {
        case .peer:
            break
        case let .header(name):
            // If a proxy appends rather than replaces, its value comes last.
            if let value = headers[name].last?.split(separator: ",").last?.trimmingCharacters(in: .whitespaces), !value.isEmpty {
                return String(value.prefix(64))
            }
        case let .forwardedFor(trustedProxies):
            let hops = headers[canonicalForm: "X-Forwarded-For"]
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !hops.isEmpty {
                return String(hops[max(0, hops.count - trustedProxies)].prefix(64))
            }
        }
        return remoteAddress?.ipAddress ?? "unknown"
    }
}

struct RateLimitMiddleware: AsyncMiddleware {
    let limiter: RateLimiter
    let addressSource: ServerSettings.ClientAddressSource
    private let warnedAboutProxy = NIOLockedValueBox(false)

    init(limiter: RateLimiter, addressSource: ServerSettings.ClientAddressSource) {
        self.limiter = limiter
        self.addressSource = addressSource
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        if addressSource == .peer, request.headers.contains(name: "X-Forwarded-For"), !warnedAboutProxy.exchange(true) {
            request.logger.warning("Requests are coming through a proxy, but neither CLIENT_IP_HEADER nor TRUSTED_PROXY_COUNT is set, so rate limits see every player as the proxy's address. See the README.")
        }
        guard await limiter.consume(request.clientAddress(from: addressSource)) else {
            throw AppError.rateLimited
        }
        return try await next.respond(to: request)
    }
}

extension NIOLockedValueBox where Value == Bool {
    /// Sets the value, returning what it was.
    func exchange(_ newValue: Bool) -> Bool {
        withLockedValue { value in
            defer { value = newValue }
            return value
        }
    }
}

/// Logs each request's method and path, like Vapor's `RouteLoggingMiddleware`, except that APNs
/// device tokens (`DELETE /v1/devices/:token`) are blanked out: a token identifies someone's phone,
/// and logs are shared and kept in places the database never goes.
struct RequestLoggingMiddleware: AsyncMiddleware {
    let logLevel: Logger.Level

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        request.logger.log(level: logLevel, "\(request.method) \(Self.loggablePath(request.url.path))")
        return try await next.respond(to: request)
    }

    static func loggablePath(_ path: String) -> String {
        let decoded = path.removingPercentEncoding ?? path
        let components = decoded.split(separator: "/")
        guard components.count >= 3, components[0] == "v1", components[1] == "devices" else { return decoded }
        return "/v1/devices/[redacted]"
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
