import BattleshipAPI
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RealtimeUpdate: Sendable, Hashable {
    /// The live connection is up. Anything missed while disconnected should be re-fetched now.
    case connected
    /// The connection dropped; the client is already trying to reconnect.
    case disconnected
    case event(ServerEvent)
}

/// Keeps a WebSocket open to the server's event stream and reconnects with backoff when it drops.
///
/// ```swift
/// let task = Task {
///     for await update in realtime.updates() { … }
/// }
/// task.cancel() // disconnects
/// ```
public final class RealtimeClient: Sendable {
    private let api: APIClient
    private let session: URLSession
    private let pingInterval: Duration

    public init(api: APIClient, session: URLSession = .shared, pingInterval: Duration = .seconds(20)) {
        self.api = api
        self.session = session
        self.pingInterval = pingInterval
    }

    /// Connects and stays connected until the iterating task is cancelled or the session ends.
    public func updates() -> AsyncStream<RealtimeUpdate> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let task = Task { [api, session, pingInterval] in
                await Self.run(api: api, session: session, pingInterval: pingInterval, continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func run(
        api: APIClient,
        session: URLSession,
        pingInterval: Duration,
        continuation: AsyncStream<RealtimeUpdate>.Continuation
    ) async {
        var consecutiveFailures = 0

        while !Task.isCancelled {
            guard let request = api.eventsRequest() else { break }
            let socket = session.webSocketTask(with: request)
            socket.resume()

            let pinger = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: pingInterval)
                    guard !Task.isCancelled else { return }
                    socket.sendPing { error in
                        if error != nil { socket.cancel(with: .goingAway, reason: nil) }
                    }
                }
            }

            var connected = false
            do {
                while !Task.isCancelled {
                    let message = try await withTaskCancellationHandler {
                        try await socket.receive()
                    } onCancel: {
                        socket.cancel(with: .goingAway, reason: nil)
                    }
                    guard let event = decode(message) else { continue }
                    if case .hello = event {
                        connected = true
                        consecutiveFailures = 0
                        continuation.yield(.connected)
                    } else {
                        continuation.yield(.event(event))
                    }
                }
            } catch {
                // Fall through and reconnect.
            }

            pinger.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            if connected {
                continuation.yield(.disconnected)
            }
            if Task.isCancelled { break }

            if (socket.response as? HTTPURLResponse)?.statusCode == 401 {
                api.handleUnauthorized()
                break
            }

            consecutiveFailures += 1
            let backoff = min(30.0, pow(2.0, Double(consecutiveFailures - 1))) + Double.random(in: 0..<1)
            try? await Task.sleep(for: .milliseconds(Int(backoff * 1000)))
        }
        continuation.finish()
    }

    private static func decode(_ message: URLSessionWebSocketTask.Message) -> ServerEvent? {
        let data: Data
        if case let .string(text) = message {
            data = Data(text.utf8)
        } else if case let .data(binary) = message {
            data = binary
        } else {
            return nil
        }
        // Ignore events this version of the app doesn't understand.
        return try? APICoding.makeDecoder().decode(ServerEvent.self, from: data)
    }
}
