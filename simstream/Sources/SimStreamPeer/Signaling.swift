import Foundation
import MaccheriProtocol

/// One side of a session's signaling channel.
public protocol SignalingTransport: Sendable {
    func send(_ message: SignalMessage) async throws
    /// The next message from the other side; nil once the channel is closed.
    func receive() async throws -> SignalMessage?
    func close()
}

/// The control plane's signaling WebSocket (`SignalingInfo.url`, token already in the query).
/// Each text frame is one JSON ``SignalMessage``.
public final class WebSocketSignaling: SignalingTransport, @unchecked Sendable {
    private let task: URLSessionWebSocketTask
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(url: URL, session: URLSession = .shared) {
        task = session.webSocketTask(with: url)
        task.resume()
    }

    public func send(_ message: SignalMessage) async throws {
        try await task.send(.string(String(decoding: try encoder.encode(message), as: UTF8.self)))
    }

    public func receive() async throws -> SignalMessage? {
        while true {
            let frame: URLSessionWebSocketTask.Message
            do {
                frame = try await task.receive()
            } catch {
                if task.closeCode != .invalid { return nil }
                throw error
            }
            let data: Data = switch frame {
            case .string(let s): Data(s.utf8)
            case .data(let d): d
            @unknown default: Data()
            }
            do {
                return try decoder.decode(SignalMessage.self, from: data)
            } catch {
                // A newer peer may send kinds this one doesn't know; skip them.
                print("signaling: ignoring \(String(decoding: data.prefix(200), as: UTF8.self)): \(error)")
            }
        }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

/// An in-memory pair of transports, for tests and for running both peers in one process.
public final class LocalSignaling: SignalingTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inbox: [SignalMessage] = []
    private var waiters: [CheckedContinuation<SignalMessage?, Never>] = []
    private var closed = false
    private weak var other: LocalSignaling?
    /// Every message this side sent, in order.
    public private(set) var sent: [SignalMessage] = []

    public static func pair() -> (LocalSignaling, LocalSignaling) {
        let a = LocalSignaling(), b = LocalSignaling()
        a.other = b
        b.other = a
        return (a, b)
    }

    public func send(_ message: SignalMessage) async throws {
        lock.withLock { sent.append(message) }
        other?.deliver(message)
    }

    private func deliver(_ message: SignalMessage?) {
        let waiter: CheckedContinuation<SignalMessage?, Never>? = lock.withLock {
            if closed { return nil }
            if message == nil { closed = true }
            if !waiters.isEmpty { return waiters.removeFirst() }
            if let message { inbox.append(message) }
            return nil
        }
        waiter?.resume(returning: message)
        if message == nil {
            let rest = lock.withLock { () -> [CheckedContinuation<SignalMessage?, Never>] in
                defer { waiters = [] }
                return waiters
            }
            rest.forEach { $0.resume(returning: nil) }
        }
    }

    public func receive() async throws -> SignalMessage? {
        await withCheckedContinuation { continuation in
            let ready: SignalMessage?? = lock.withLock {
                if !inbox.isEmpty { return .some(inbox.removeFirst()) }
                if closed { return .some(nil) }
                waiters.append(continuation)
                return .none
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    public func close() {
        deliver(nil)
        other?.deliver(nil)
    }
}
