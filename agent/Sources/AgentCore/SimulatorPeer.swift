import Foundation
import MaccheriProtocol
import Network

/// The host's end of a simulator session: talks to the viewer over signaling and WebRTC and to
/// simstream in the guest through `connectToGuest`. D's `HostPeer` (simstream package) is the
/// real one; ``SignalingStubPeer`` stands in until it lands.
public protocol SimulatorPeer: Sendable {
    /// Returns when the viewer leaves (bye, disconnect, timeout). Must honour task cancellation.
    func run(signaling: SignalingInfo, sessionID: UUID, connectToGuest: @escaping @Sendable () async throws -> NWConnection) async throws
}

/// Joins signaling as the host and waits for the viewer's `bye`, without any media. Enough to
/// drive the session lifecycle end to end; also checks once that the guest's simstream answers.
public struct SignalingStubPeer: SimulatorPeer {
    private let log: @Sendable (String) -> Void

    public init(log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.log = log
    }

    public func run(signaling: SignalingInfo, sessionID: UUID, connectToGuest: @escaping @Sendable () async throws -> NWConnection) async throws {
        let guest = try await connectToGuest()
        log("session \(sessionID): stub peer reached simstream")
        guest.cancel()

        let socket = URLSession.shared.webSocketTask(with: signaling.url)
        socket.resume()
        try await withTaskCancellationHandler {
            while true {
                let message = try await socket.receive()
                guard case let .string(text) = message,
                      let signal = try? JSONDecoder.maccheri.decode(SignalMessage.self, from: Data(text.utf8)) else { continue }
                switch signal {
                case let .bye(reason):
                    log("session \(sessionID): viewer left\(reason.map { " (\($0))" } ?? "")")
                    socket.cancel(with: .normalClosure, reason: nil)
                    return
                case .answer, .candidate, .offer:
                    log("session \(sessionID): stub peer ignores \(text.prefix(40))…")
                }
            }
        } onCancel: {
            let bye = (try? JSONEncoder.maccheri.encode(SignalMessage.bye(reason: "host ended the session"))).map { String(decoding: $0, as: UTF8.self) }
            if let bye {
                socket.send(.string(bye)) { _ in socket.cancel(with: .normalClosure, reason: nil) }
            } else {
                socket.cancel(with: .normalClosure, reason: nil)
            }
        }
    }
}

extension NWConnection {
    /// A started TCP connection to `127.0.0.1:port`, once it is ready.
    public static func loopback(port: UInt16, queue: DispatchQueue = DispatchQueue(label: "guest-connection", qos: .userInteractive)) async throws -> NWConnection {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: nil, tcp: tcp))
        let box = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: box.run { continuation.resume() }
                case let .failed(error), let .waiting(error): box.run { continuation.resume(throwing: error) }
                case .cancelled: box.run { continuation.resume(throwing: CancellationError()) }
                default: break
                }
            }
            connection.start(queue: queue)
        }
        connection.stateUpdateHandler = nil
        return connection
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}
