import BattleshipAPI
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOWebSocket
import Vapor

/// Tracks open WebSocket connections and fans events out to each player's devices.
///
/// Connections live in memory, so the server is designed to run as a single instance.
///
/// Events are sent while the write lock is held (so players hear about changes in commit order),
/// which is why nothing here waits for the network: writes are queued on the connection and the
/// hub moves on. A client that stops reading would otherwise stall the lock, and with it every
/// write on the server, until its TCP connection died. Instead each connection may have only
/// ``maxUnacknowledgedWrites`` writes still waiting to reach the network; one more and it's cut off.
/// Its app reconnects when it can and catches up by reloading its games.
actor RealtimeHub {
    static let maxUnacknowledgedWrites = 32
    /// Connections per player. Each holds memory and a socket; a player rarely has more than a phone
    /// and an iPad open.
    static let maxConnectionsPerPlayer = 5
    /// How long a closing connection gets to finish the closing handshake before it's cut off.
    static let closeTimeout: TimeAmount = .seconds(10)
    /// How long a player's last connection is remembered; longer than matchmaking ever looks back.
    static let activityRetention: TimeInterval = 60 * 60

    private struct Connection {
        let socket: WebSocket
        /// The socket's NIO channel, to cut off a client that stopped reading: a close frame would
        /// queue behind everything it hasn't read and never arrive.
        let channel: any Channel
        let tokenID: UUID?
        /// Registration order, to find a player's oldest connection.
        let sequence: Int
        let backlog: WriteBacklog
    }

    /// Writes queued on a connection that the network hasn't taken yet.
    private final class WriteBacklog: Sendable {
        private let count = NIOLockedValueBox(0)

        /// Counts a new write; returns how many are now outstanding.
        func begin() -> Int {
            count.withLockedValue { $0 += 1; return $0 }
        }

        func finish() {
            count.withLockedValue { $0 -= 1 }
        }

        var outstanding: Int { count.withLockedValue { $0 } }
    }

    private var connections: [UUID: [ObjectIdentifier: Connection]] = [:]
    /// When each player's last connection closed, for matchmaking (see ``isActive(_:since:)``).
    private var lastDisconnected: [UUID: Date] = [:]
    private var lastPruned = Date()
    private var nextSequence = 0
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    /// Starts sending `userID`'s events to `socket`, beginning with ``ServerEvent/hello``. Closes the
    /// player's oldest connection if they already have ``maxConnectionsPerPlayer``.
    func register(_ socket: WebSocket, channel: any Channel, userID: UUID, tokenID: UUID?) {
        guard !socket.isClosed else { return }
        var sockets = connections[userID, default: [:]]
        while sockets.count >= Self.maxConnectionsPerPlayer,
              let oldest = sockets.min(by: { $0.value.sequence < $1.value.sequence }) {
            sockets[oldest.key] = nil
            close(oldest.value, code: .policyViolation)
        }
        nextSequence += 1
        let connection = Connection(socket: socket, channel: channel, tokenID: tokenID, sequence: nextSequence, backlog: WriteBacklog())
        sockets[ObjectIdentifier(socket)] = connection
        connections[userID] = sockets
        if let hello = encode(.hello) {
            write(hello, to: connection, userID: userID)
        }
    }

    func unregister(_ socket: WebSocket, userID: UUID) {
        remove(ObjectIdentifier(socket), of: userID)
    }

    func connectionCount(for userID: UUID) -> Int {
        connections[userID]?.count ?? 0
    }

    /// Whether `userID` is connected now, or was at any point since `date`.
    func isActive(_ userID: UUID, since date: Date) -> Bool {
        connections[userID] != nil || lastDisconnected[userID].map { $0 >= date } == true
    }

    /// Writes not yet taken by the network, across `userID`'s connections. For tests.
    func unacknowledgedWrites(for userID: UUID) -> Int {
        connections[userID]?.values.reduce(0) { $0 + $1.backlog.outstanding } ?? 0
    }

    /// Queues `event` on each of `userID`'s connections. Never waits for the network.
    func send(_ event: ServerEvent, to userID: UUID) {
        guard let targets = connections[userID]?.values, !targets.isEmpty, let text = encode(event) else { return }
        for connection in targets {
            write(text, to: connection, userID: userID)
        }
    }

    /// Closes the sockets opened with a session token that has just been revoked.
    func disconnect(tokenID: UUID) {
        for (userID, sockets) in connections {
            for (key, connection) in sockets where connection.tokenID == tokenID {
                remove(key, of: userID)
                close(connection, code: .normalClosure)
            }
        }
    }

    func disconnectAll(userID: UUID) {
        let closing = connections.removeValue(forKey: userID) ?? [:]
        for connection in closing.values {
            close(connection, code: .normalClosure)
        }
        lastDisconnected[userID] = nil
    }

    private func write(_ text: String, to connection: Connection, userID: UUID) {
        guard connection.backlog.begin() <= Self.maxUnacknowledgedWrites else {
            connection.backlog.finish()
            logger.notice("Dropping a realtime connection that stopped reading", metadata: ["user": "\(userID)"])
            remove(ObjectIdentifier(connection.socket), of: userID)
            Self.cutOff(connection.channel)
            return
        }
        let written = connection.channel.eventLoop.makePromise(of: Void.self)
        let backlog = connection.backlog
        written.futureResult.whenComplete { _ in backlog.finish() }
        connection.socket.send(text, promise: written)
    }

    private func remove(_ key: ObjectIdentifier, of userID: UUID) {
        guard connections[userID]?.removeValue(forKey: key) != nil else { return }
        // Their last connection: remember when, for matchmaking.
        guard connections[userID]?.isEmpty == true else { return }
        connections[userID] = nil
        let now = Date()
        lastDisconnected[userID] = now
        if now.timeIntervalSince(lastPruned) > 10 * 60 {
            lastPruned = now
            lastDisconnected = lastDisconnected.filter { now.timeIntervalSince($0.value) < Self.activityRetention }
        }
    }

    /// Starts the closing handshake, and cuts the connection off if it hasn't finished in time.
    private func close(_ connection: Connection, code: WebSocketErrorCode) {
        connection.socket.close(code: code, promise: nil)
        let channel = connection.channel
        channel.eventLoop.scheduleTask(in: Self.closeTimeout) {
            if channel.isActive {
                Self.cutOff(channel)
            }
        }
    }

    /// Closes a connection at once, discarding whatever the client hasn't read (TCP reset). An
    /// ordinary close would leave the kernel trying to deliver that backlog for minutes.
    private static func cutOff(_ channel: any Channel) {
        guard let options = channel as? any SocketOptionProvider else {
            channel.close(mode: .all, promise: nil)
            return
        }
        options.setSoLinger(linger(l_onoff: 1, l_linger: 0)).whenComplete { _ in
            channel.close(mode: .all, promise: nil)
        }
    }

    private func encode(_ event: ServerEvent) -> String? {
        guard let data = try? APICoding.makeEncoder().encode(event) else {
            logger.error("Could not encode realtime event")
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Vapor's WebSocket upgrade, keeping hold of the connection's NIO channel for ``RealtimeHub``.
struct EventStreamUpgrader: Upgrader {
    let onUpgrade: @Sendable (WebSocket, any Channel) -> Void

    func applyUpgrade(req: Request, res: Response) -> any HTTPServerProtocolUpgrader {
        NIOWebSocketServerUpgrader(
            // Vapor's default. Clients only ever send control frames.
            maxFrameSize: 1 << 14,
            automaticErrorHandling: false,
            shouldUpgrade: { channel, _ in channel.eventLoop.makeSucceededFuture([:]) },
            upgradePipelineHandler: { channel, _ in
                WebSocket.server(on: channel) { socket in onUpgrade(socket, channel) }
            }
        )
    }
}
