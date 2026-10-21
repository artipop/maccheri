import Foundation
import MaccheriProtocol
import NIOConcurrencyHelpers
import Vapor
import NIOWebSocket

/// Relays signaling frames between the viewer and the host of each session. See ``SignalingAPI``.
///
/// One socket per role; a new connection of the same role replaces the old one (a reloaded tab).
/// Frames for a role that isn't connected wait in a bounded queue.
final class SignalHub: Sendable {
    static let maxQueuedFrames = 256
    static let maxFrameBytes = 64 * 1024
    /// Close code for a socket replaced by a newer connection of the same role.
    static let replacedCloseCode: WebSocketErrorCode = .unknown(4000)

    private struct Room {
        var sockets: [SignalingRole: WebSocket] = [:]
        /// Frames waiting for a role to connect.
        var pending: [SignalingRole: [String]] = [:]
    }

    private let rooms = NIOLockedValueBox<[UUID: Room]>([:])

    func join(session: UUID, role: SignalingRole, socket: WebSocket, logger: Logger) {
        let (replaced, backlog) = rooms.withLockedValue { rooms -> (WebSocket?, [String]) in
            var room = rooms[session] ?? Room()
            let replaced = room.sockets[role]
            room.sockets[role] = socket
            let backlog = room.pending.removeValue(forKey: role) ?? []
            rooms[session] = room
            return (replaced, backlog)
        }
        if let replaced { _ = replaced.close(code: Self.replacedCloseCode) }
        logger.info("signaling joined", metadata: ["session": "\(session)", "role": "\(role.rawValue)", "backlog": "\(backlog.count)"])

        // WebSocket callbacks belong to the socket's event loop. The signaling route calls this
        // on that loop, so handlers are set before the first frame is read.
        let setUp: @Sendable () -> Void = { [weak self] in
            socket.pingInterval = .seconds(20)
            socket.onText { socket, text in
                guard text.utf8.count <= Self.maxFrameBytes else {
                    _ = socket.close(code: .messageTooLarge)
                    return
                }
                self?.forward(text, from: role, in: session)
            }
            socket.onBinary { socket, _ in
                _ = socket.close(code: .unacceptableData)
            }
            socket.onClose.whenComplete { _ in
                self?.leave(session: session, role: role, socket: socket)
            }
            for frame in backlog { socket.send(frame) }
        }
        if socket.eventLoop.inEventLoop { setUp() } else { socket.eventLoop.execute(setUp) }
    }

    /// Sends `bye` to whoever is connected, closes both sides and forgets the session.
    func end(session: UUID, reason: String?) {
        guard let room = rooms.withLockedValue({ $0.removeValue(forKey: session) }) else { return }
        let bye = Self.encode(.bye(reason: reason))
        for socket in room.sockets.values {
            socket.send(bye, promise: nil)
            _ = socket.close(code: .normalClosure)
        }
    }

    func connectedRoles(session: UUID) -> Set<SignalingRole> {
        rooms.withLockedValue { Set($0[session].map { Array($0.sockets.keys) } ?? []) }
    }

    private func forward(_ text: String, from role: SignalingRole, in session: UUID) {
        let other: SignalingRole = role == .viewer ? .host : .viewer
        let target = rooms.withLockedValue { rooms -> WebSocket? in
            guard var room = rooms[session] else { return nil }
            if let socket = room.sockets[other] { return socket }
            var queue = room.pending[other] ?? []
            queue.append(text)
            if queue.count > Self.maxQueuedFrames { queue.removeFirst(queue.count - Self.maxQueuedFrames) }
            room.pending[other] = queue
            rooms[session] = room
            return nil
        }
        target?.send(text)
    }

    private func leave(session: UUID, role: SignalingRole, socket: WebSocket) {
        rooms.withLockedValue { rooms in
            // A replaced socket closing must not drop its replacement.
            guard var room = rooms[session], room.sockets[role] === socket else { return }
            room.sockets[role] = nil
            rooms[session] = room
        }
    }

    static func encode(_ message: SignalMessage) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! encoder.encode(message), as: UTF8.self)
    }
}
