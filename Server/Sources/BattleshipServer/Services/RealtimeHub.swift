import BattleshipAPI
import Vapor

/// Tracks open WebSocket connections and fans events out to each player's devices.
///
/// Connections live in memory, so the server is designed to run as a single instance.
actor RealtimeHub {
    private struct Connection {
        let socket: WebSocket
        let tokenID: UUID?
    }

    private var connections: [UUID: [ObjectIdentifier: Connection]] = [:]
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func register(_ socket: WebSocket, userID: UUID, tokenID: UUID?) {
        connections[userID, default: [:]][ObjectIdentifier(socket)] = Connection(socket: socket, tokenID: tokenID)
    }

    func unregister(_ socket: WebSocket, userID: UUID) {
        connections[userID]?[ObjectIdentifier(socket)] = nil
        if connections[userID]?.isEmpty == true {
            connections[userID] = nil
        }
    }

    func connectionCount(for userID: UUID) -> Int {
        connections[userID]?.count ?? 0
    }

    func send(_ event: ServerEvent, to userID: UUID) async {
        guard let targets = connections[userID]?.values, !targets.isEmpty else { return }
        guard let data = try? APICoding.makeEncoder().encode(event) else {
            logger.error("Could not encode realtime event")
            return
        }
        let text = String(decoding: data, as: UTF8.self)
        for connection in targets where !connection.socket.isClosed {
            try? await connection.socket.send(text)
        }
    }

    /// Closes the sockets opened with a session token that has just been revoked.
    func disconnect(tokenID: UUID) async {
        for (userID, sockets) in connections {
            for (key, connection) in sockets where connection.tokenID == tokenID {
                connections[userID]?[key] = nil
                try? await connection.socket.close(code: .normalClosure)
            }
        }
    }

    func disconnectAll(userID: UUID) async {
        let sockets = connections.removeValue(forKey: userID)?.values.map(\.socket) ?? []
        for socket in sockets {
            try? await socket.close(code: .normalClosure)
        }
    }
}
