import BattleshipAPI
import BattleshipCore
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Talks to the Battleships server's REST API.
///
/// Safe to share across tasks. Set ``token`` after signing in; every authenticated call sends it as a
/// bearer token. When the server rejects the token, calls throw ``APIError/unauthorized`` and the
/// handler installed with ``setUnauthorizedHandler(_:)`` runs, so the app can return to sign-in.
public final class APIClient: Sendable {
    public let baseURL: URL
    private let session: URLSession
    private let state: Locked<State>

    private struct State {
        var token: String?
        var onUnauthorized: (@Sendable () -> Void)?
    }

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        self.state = Locked(State(token: token))
    }

    public var token: String? {
        get { state.withLock { $0.token } }
        set { state.withLock { $0.token = newValue } }
    }

    public func setUnauthorizedHandler(_ handler: (@Sendable () -> Void)?) {
        state.withLock { $0.onUnauthorized = handler }
    }

    func handleUnauthorized() {
        let handler = state.withLock { $0.onUnauthorized }
        handler?()
    }

    // MARK: Accounts

    public func register(_ credentials: Credentials) async throws -> AuthResponse {
        try await send("POST", "v1/auth/register", body: credentials, authenticated: false)
    }

    public func signIn(_ credentials: Credentials) async throws -> AuthResponse {
        try await send("POST", "v1/auth/login", body: credentials, authenticated: false)
    }

    /// Revokes the current session token on the server.
    public func signOut() async throws {
        try await sendWithoutResponse("POST", "v1/auth/logout")
    }

    public func account() async throws -> Account {
        try await send("GET", "v1/me")
    }

    /// Permanently deletes the signed-in account. Active games are resigned.
    public func deleteAccount() async throws {
        try await sendWithoutResponse("DELETE", "v1/me")
    }

    // MARK: Players

    public func searchPlayers(prefix: String) async throws -> [PlayerSummary] {
        try await send("GET", "v1/players", query: [URLQueryItem(name: "prefix", value: prefix)])
    }

    public func leaderboard() async throws -> [LeaderboardEntry] {
        try await send("GET", "v1/leaderboard")
    }

    // MARK: Games

    /// Your unfinished games plus your most recent finished ones.
    public func games() async throws -> [GameSummary] {
        try await send("GET", "v1/games")
    }

    public func game(id: UUID) async throws -> GameDetail {
        try await send("GET", "v1/games/\(id.uuidString)")
    }

    /// Joins matchmaking, or challenges `request.opponent` if set.
    public func createGame(_ request: CreateGameRequest) async throws -> GameDetail {
        try await send("POST", "v1/games", body: request)
    }

    public func acceptChallenge(gameID: UUID, fleet: [ShipPlacement]) async throws -> GameDetail {
        try await send("POST", "v1/games/\(gameID.uuidString)/accept", body: AcceptChallengeRequest(fleet: fleet))
    }

    public func declineChallenge(gameID: UUID) async throws {
        try await sendWithoutResponse("POST", "v1/games/\(gameID.uuidString)/decline")
    }

    /// Withdraws a game you created that hasn't started (matchmaking or an unanswered challenge).
    public func cancelGame(gameID: UUID) async throws {
        try await sendWithoutResponse("POST", "v1/games/\(gameID.uuidString)/cancel")
    }

    public func resign(gameID: UUID) async throws -> GameDetail {
        try await send("POST", "v1/games/\(gameID.uuidString)/resign")
    }

    public func fire(gameID: UUID, at target: Coordinate) async throws -> FireResponse {
        try await send("POST", "v1/games/\(gameID.uuidString)/shots", body: FireRequest(target: target))
    }

    // MARK: Push notifications

    public func registerDevice(_ registration: DeviceRegistration) async throws {
        try await sendWithoutResponse("POST", "v1/devices", body: registration)
    }

    public func unregisterDevice(token deviceToken: String) async throws {
        try await sendWithoutResponse("DELETE", "v1/devices/\(deviceToken)")
    }

    // MARK: Realtime

    /// The WebSocket request for the realtime event stream, or `nil` when signed out.
    public func eventsRequest() -> URLRequest? {
        guard let token,
              var components = URLComponents(url: url(for: "v1/events"), resolvingAgainstBaseURL: false)
        else { return nil }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: Plumbing

    private func url(for path: String) -> URL {
        baseURL.appending(path: path)
    }

    private func send<Response: Decodable>(
        _ method: String,
        _ path: String,
        query: [URLQueryItem] = [],
        authenticated: Bool = true
    ) async throws -> Response {
        let data = try await perform(method, path, query: query, body: nil, authenticated: authenticated)
        return try decode(Response.self, from: data)
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ method: String,
        _ path: String,
        body: Body?,
        authenticated: Bool = true
    ) async throws -> Response {
        let encoded = try body.map { try APICoding.makeEncoder().encode($0) }
        let data = try await perform(method, path, query: [], body: encoded, authenticated: authenticated)
        return try decode(Response.self, from: data)
    }

    private func sendWithoutResponse(_ method: String, _ path: String) async throws {
        _ = try await perform(method, path, query: [], body: nil, authenticated: true)
    }

    private func sendWithoutResponse<Body: Encodable>(_ method: String, _ path: String, body: Body) async throws {
        let encoded = try APICoding.makeEncoder().encode(body)
        _ = try await perform(method, path, query: [], body: encoded, authenticated: true)
    }

    private func perform(
        _ method: String,
        _ path: String,
        query: [URLQueryItem],
        body: Data?,
        authenticated: Bool
    ) async throws -> Data {
        var url = url(for: path)
        if !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            url = components.url ?? url
        }

        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authenticated {
            guard let token else { throw APIError.unauthorized }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError {
            throw APIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse("Not an HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            return data
        case 401 where authenticated:
            handleUnauthorized()
            throw APIError.unauthorized
        default:
            if let body = try? APICoding.makeDecoder().decode(APIErrorBody.self, from: data) {
                throw APIError.server(status: http.statusCode, body: body)
            }
            throw APIError.server(
                status: http.statusCode,
                body: APIErrorBody(
                    code: http.statusCode >= 500 ? .internalError : .badRequest,
                    message: "The server returned an error (HTTP \(http.statusCode))."
                )
            )
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try APICoding.makeDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.invalidResponse(String(describing: error))
        }
    }
}

/// A value guarded by a lock, for state shared across concurrent tasks.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
