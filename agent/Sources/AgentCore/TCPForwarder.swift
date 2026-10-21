import Foundation
import Network

/// Relays TCP connections from a port on all host interfaces to a port in the guest, which sits
/// behind vmnet's NAT. Bytes are passed on as soon as they arrive, with Nagle off on both legs:
/// it carries interactive traffic (the simulator stream), so latency beats throughput.
public final class TCPForwarder: @unchecked Sendable {
    public struct Mapping: Sendable, Equatable, CustomStringConvertible {
        public var hostPort: UInt16
        public var guestPort: UInt16

        public init(hostPort: UInt16, guestPort: UInt16) {
            self.hostPort = hostPort
            self.guestPort = guestPort
        }

        /// `"7300:7300"` or just `"7300"` for the same port on both sides.
        public init?(_ spec: String) {
            let parts = spec.split(separator: ":", omittingEmptySubsequences: false).map { UInt16($0) }
            guard (1...2).contains(parts.count), let host = parts[0], let guest = parts.last!, host != 0, guest != 0 else { return nil }
            self.init(hostPort: host, guestPort: guest)
        }

        public var description: String { "\(hostPort):\(guestPort)" }
    }

    public let mapping: Mapping
    public let guestHost: String
    private let listener: NWListener
    private let queue = DispatchQueue(label: "forward", qos: .userInteractive)
    private let log: @Sendable (String) -> Void

    public init(_ mapping: Mapping, guestHost: String, log: @escaping @Sendable (String) -> Void = { _ in }) throws {
        self.mapping = mapping
        self.guestHost = guestHost
        self.log = log
        listener = try NWListener(using: Self.parameters(), on: NWEndpoint.Port(rawValue: mapping.hostPort)!)
    }

    /// The bound port once started (differs from the mapping only if that asked for port 0).
    public var port: UInt16? { listener.port?.rawValue }

    /// Returns once the listener is ready (or throws if it can't bind).
    public func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // Handlers run on `queue`, one at a time; `starting` is only touched there.
            starting = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.starting?.resume()
                    self.starting = nil
                case .failed(let error):
                    self.log("forward \(self.mapping): \(error)")
                    self.starting?.resume(throwing: error)
                    self.starting = nil
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] in self?.relay($0) }
            listener.start(queue: queue)
        }
    }

    private var starting: CheckedContinuation<Void, any Error>?

    public func stop() {
        listener.cancel()
    }

    private static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.allowLocalEndpointReuse = true
        return parameters
    }

    private func relay(_ inbound: NWConnection) {
        let outbound = NWConnection(host: NWEndpoint.Host(guestHost), port: NWEndpoint.Port(rawValue: mapping.guestPort)!, using: Self.parameters())
        let peer = "\(inbound.endpoint)"
        log("forward \(mapping): \(peer) connected")
        let close: @Sendable () -> Void = {
            inbound.cancel()
            outbound.cancel()
        }
        for connection in [inbound, outbound] {
            connection.stateUpdateHandler = { [log, mapping] state in
                switch state {
                case .failed(let error):
                    log("forward \(mapping): \(peer): \(error)")
                    close()
                case .cancelled:
                    close()
                default:
                    break
                }
            }
        }
        inbound.start(queue: queue)
        outbound.start(queue: queue)
        pump(from: inbound, to: outbound, close: close)
        pump(from: outbound, to: inbound, close: close)
    }

    /// Reads whatever has arrived and writes it on unchanged; the next read waits for the write
    /// to be handed to the socket, so a slow reader backs up into TCP instead of into memory.
    private func pump(from source: NWConnection, to destination: NWConnection, close: @escaping @Sendable () -> Void) {
        // Strong self: the chain ends when either side closes.
        source.receive(minimumIncompleteLength: 1, maximumLength: 256 << 10) { data, _, isComplete, error in
            if let data, !data.isEmpty {
                destination.send(content: data, completion: .contentProcessed { sendError in
                    if sendError != nil { return close() }
                    if isComplete || error != nil { return close() }
                    self.pump(from: source, to: destination, close: close)
                })
            } else if isComplete || error != nil {
                close()
            } else {
                self.pump(from: source, to: destination, close: close)
            }
        }
    }
}
