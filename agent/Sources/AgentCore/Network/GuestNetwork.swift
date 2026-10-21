import Darwin
import Foundation

/// The guest's whole network, in user space: the VM's NIC is one end of a datagram socketpair
/// (`VZFileHandleNetworkDeviceAttachment`), and this class is everything on the other end: an
/// Ethernet segment with a gateway, DHCP, a DNS forwarder and a NAT that turns the guest's TCP,
/// UDP and ICMP echo into ordinary host sockets, but only towards destinations that
/// ``EgressPolicy`` permits. The guest's subnet exists nowhere on the host, so nothing on the
/// host or the owner's LAN can reach the guest either; the agent itself gets in through
/// ``forward(guestPort:hostPort:)`` and ``probe(port:)``.
///
/// No root, no pf, no vmnet: each VM gets its own instance. Call ``stop()`` when the VM is gone.
public final class GuestNetwork: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var gateway = IPv4(10, 233, 0, 1)
        public var guest = IPv4(10, 233, 0, 2)
        public var netmask = IPv4(255, 255, 255, 0)
        public var mtu = 1500
        public var policy = EgressPolicy.internetOnly
        /// Upstream DNS servers; nil asks the host's.
        public var resolvers: [IPv4]?

        public init() {}
    }

    public let configuration: Configuration
    public let guestMAC: MACAddress
    let gatewayMAC = MACAddress([0x5A, 0x94, 0xEF, 0xE4, 0x0C, 0xEE])
    /// The guest's end of the socketpair, for `VZFileHandleNetworkDeviceAttachment`.
    public let guestFileHandle: FileHandle

    let queue = DispatchQueue(label: "guest-network", qos: .userInteractive)
    let log: @Sendable (String) -> Void
    private let fd: Int32
    private var link: SocketWatcher?
    private var outbox: [[UInt8]] = []
    private var tcp: [TCPFlow.Key: TCPFlow] = [:]
    private var udp: [UDPFlow.Key: UDPFlow] = [:]
    private var icmp: ICMPRelay?
    private var forwards: [UInt16: SocketWatcher] = [:]
    private var nextPort: UInt16 = 49152
    private var ipID: UInt16 = 0
    private var sweeper: (any DispatchSourceTimer)?
    private var leaseWaiters: [CheckedContinuation<Void, Never>] = []
    private var hasLease = false
    private var stopped = false

    var maxSegmentSize: Int { configuration.mtu - 40 }
    /// Frames are waiting for room in the socket buffer; senders back off.
    var linkBusy: Bool { !outbox.isEmpty }

    static let maxTCPFlows = 2048
    static let maxUDPFlows = 512

    public init(guestMAC: MACAddress, configuration: Configuration = Configuration(), log: @escaping @Sendable (String) -> Void = { _ in }) throws {
        self.configuration = configuration
        self.guestMAC = guestMAC
        self.log = log
        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &fds) == 0 else {
            throw NetworkError.system("socketpair", errno)
        }
        // Apple's guidance for the file-handle attachment: large buffers, receive ≥ 2× send.
        for socket in fds {
            SocketOptions.set(socket, SOL_SOCKET, SO_SNDBUF, 1 << 20)
            SocketOptions.set(socket, SOL_SOCKET, SO_RCVBUF, 4 << 20)
        }
        fd = fds[0]
        guestFileHandle = FileHandle(fileDescriptor: fds[1], closeOnDealloc: true)
        SocketOptions.setNonBlocking(fd)
    }

    public func start() {
        queue.async { [self] in
            link = SocketWatcher(fd: fd, queue: queue, onReadable: { [unowned self] in readFrames() }, onWritable: { [unowned self] in drainOutbox() })
            link?.setReading(true)
            let sweeper = DispatchSource.makeTimerSource(queue: queue)
            sweeper.schedule(deadline: .now() + 10, repeating: 10)
            sweeper.setEventHandler { [unowned self] in sweep() }
            sweeper.resume()
            self.sweeper = sweeper
        }
    }

    public func stop() {
        queue.sync {
            guard !stopped else { return }
            stopped = true
            sweeper?.cancel()
            for flow in Array(tcp.values) { flow.abort(notifyGuest: false) }
            tcp.removeAll()
            for flow in udp.values { flow.socket.close() }
            udp.removeAll()
            icmp?.socket.close()
            icmp = nil
            for listener in forwards.values { listener.close() }
            forwards.removeAll()
            link?.close()
            link = nil
            for waiter in leaseWaiters { waiter.resume() }
            leaseWaiters.removeAll()
        }
    }

    // MARK: Agent's way in

    /// Whether something in the guest accepts TCP connections on `port` right now.
    public func probe(port: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard !stopped else { return continuation.resume(returning: false) }
                let key = TCPFlow.Key(guestPort: port, remote: configuration.gateway, remotePort: allocatePort())
                var once = false
                tcp[key] = TCPFlow(connectingTo: key, fd: nil, origin: .probe({ accepted in
                    guard !once else { return }
                    once = true
                    continuation.resume(returning: accepted)
                }), network: self)
            }
        }
    }

    /// Listens on `127.0.0.1:hostPort` (0 picks a port) and relays each connection to `guestPort`.
    /// Returns the bound port. The listener lives until ``stop()`` or ``stopForward(_:)``.
    public func forward(guestPort: UInt16, hostPort: UInt16 = 0) throws -> UInt16 {
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw NetworkError.system("socket", errno) }
        SocketOptions.set(listener, SOL_SOCKET, SO_REUSEADDR, 1)
        var address = IPv4(127, 0, 0, 1).sockaddr
        address.sin_port = hostPort.bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(listener, 16) == 0 else {
            let code = errno
            close(listener)
            throw NetworkError.system("bind 127.0.0.1:\(hostPort)", code)
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(listener, $0, &length) }
        }
        let port = UInt16(bigEndian: address.sin_port)
        SocketOptions.setNonBlocking(listener)
        queue.sync {
            let watcher = SocketWatcher(fd: listener, queue: queue, onReadable: { [unowned self] in accept(on: listener, guestPort: guestPort) }, onWritable: {})
            watcher.setReading(true)
            forwards[port] = watcher
        }
        return port
    }

    public func stopForward(_ port: UInt16) {
        queue.sync { forwards.removeValue(forKey: port)?.close() }
    }

    /// Returns once the guest has taken its DHCP lease (or the network stopped).
    public func waitForLease() async {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                if hasLease || stopped { continuation.resume() } else { leaseWaiters.append(continuation) }
            }
        }
    }

    private func accept(on listener: Int32, guestPort: UInt16) {
        while true {
            let client = Darwin.accept(listener, nil, nil)
            guard client >= 0 else { return }
            let key = TCPFlow.Key(guestPort: guestPort, remote: configuration.gateway, remotePort: allocatePort())
            tcp[key] = TCPFlow(connectingTo: key, fd: client, origin: .host, network: self)
        }
    }

    private func allocatePort() -> UInt16 {
        repeat {
            nextPort = nextPort == .max ? 49152 : nextPort + 1
        } while tcp.keys.contains(where: { $0.remote == configuration.gateway && $0.remotePort == nextPort })
        return nextPort
    }

    // MARK: Frames in

    private func readFrames() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        for _ in 0..<256 {
            let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { break }
            handleFrame(Array(buffer[..<count]))
        }
        flushAcks()
    }

    func handleFrame(_ frame: [UInt8]) {
        guard frame.count >= 14 else { return }
        let type = frame.u16(12)
        let payload = Array(frame[14...])
        switch type {
        case EtherType.arp: handleARP(payload)
        case EtherType.ipv4: if let packet = IPv4Packet(payload) { handleIPv4(packet) }
        default: break // IPv6 and the rest: the guest gets IPv4 only.
        }
    }

    private func flushAcks() {
        for flow in tcp.values where flow.needsAck {
            flow.emitAck()
        }
    }

    private func handleARP(_ arp: [UInt8]) {
        guard arp.count >= 28, arp.u16(0) == 1, arp.u16(2) == EtherType.ipv4, arp.u16(6) == 1 else { return }
        let senderMAC = Array(arp[8..<14])
        let senderIP = arp.u32(14)
        let target = IPv4(arp.u32(24))
        // Only the gateway exists on this segment; the guest's own probes must go unanswered.
        guard target == configuration.gateway else { return }
        var reply = [UInt8](repeating: 0, count: 28)
        reply.put16(1, at: 0)
        reply.put16(EtherType.ipv4, at: 2)
        reply[4] = 6
        reply[5] = 4
        reply.put16(2, at: 6)
        reply.replaceSubrange(8..<14, with: gatewayMAC.bytes)
        reply.put32(configuration.gateway.value, at: 14)
        reply.replaceSubrange(18..<24, with: senderMAC)
        reply.put32(senderIP, at: 24)
        sendFrame(FrameBuilder.ethernet(to: MACAddress(senderMAC), from: gatewayMAC, type: EtherType.arp, payload: reply))
    }

    private func handleIPv4(_ packet: IPv4Packet) {
        if packet.proto == IPProtocolNumber.udp, let datagram = UDPDatagram(packet.payload), datagram.destinationPort == 67 {
            return handleDHCP(datagram.payload)
        }
        // Anti-spoofing: the guest only ever speaks as itself.
        guard packet.source == configuration.guest else { return }
        let destination = packet.destination
        let toGateway = destination == configuration.gateway
        switch packet.proto {
        case IPProtocolNumber.tcp:
            guard let segment = TCPSegment(packet.payload) else { return }
            let key = TCPFlow.Key(guestPort: segment.sourcePort, remote: destination, remotePort: segment.destinationPort)
            if let flow = tcp[key] { return flow.handle(segment) }
            guard segment.flags.contains(.syn), !segment.flags.contains(.ack) else {
                if !segment.flags.contains(.rst) { TCPFlow.refuse(segment, key: key, network: self) }
                return
            }
            guard !toGateway, configuration.policy.permits(destination), tcp.count < Self.maxTCPFlows,
                  let flow = TCPFlow(guestSYN: segment, key: key, network: self)
            else {
                return TCPFlow.refuse(segment, key: key, network: self)
            }
            tcp[key] = flow

        case IPProtocolNumber.udp:
            guard let datagram = UDPDatagram(packet.payload) else { return }
            let key = UDPFlow.Key(guestPort: datagram.sourcePort, remote: destination, remotePort: datagram.destinationPort)
            if let flow = udp[key] { return flow.send(datagram.payload) }
            var upstream = (destination, datagram.destinationPort)
            if toGateway {
                guard datagram.destinationPort == 53 else { return }
                upstream = ((configuration.resolvers ?? HostResolvers.current()).first ?? IPv4(1, 1, 1, 1), 53)
            } else {
                guard configuration.policy.permits(destination) else { return }
            }
            guard udp.count < Self.maxUDPFlows, let flow = UDPFlow(key: key, upstream: upstream, network: self) else { return }
            udp[key] = flow
            flow.send(datagram.payload)

        case IPProtocolNumber.icmp:
            let message = Array(packet.payload)
            guard message.count >= 8, message[0] == 8 else { return }
            if toGateway {
                var reply = message
                reply[0] = 0
                return sendIP(FrameBuilder.icmp(from: configuration.gateway, to: configuration.guest, message: reply))
            }
            guard configuration.policy.permits(destination) else { return }
            if icmp == nil { icmp = ICMPRelay(network: self) }
            icmp?.send(message, to: destination)

        default:
            break
        }
    }

    // MARK: DHCP

    private func handleDHCP(_ payload: ArraySlice<UInt8>) {
        let request = Array(payload)
        guard request.count >= 240, request[0] == 1, request.u32(236) == 0x6382_5363 else { return }
        var messageType: UInt8 = 0
        var requested: IPv4?
        var i = 240
        while i < request.count {
            let code = request[i]
            if code == 255 { break }
            if code == 0 { i += 1; continue }
            guard i + 1 < request.count else { break }
            let length = Int(request[i + 1])
            guard i + 2 + length <= request.count else { break }
            if code == 53, length == 1 { messageType = request[i + 2] }
            if code == 50, length == 4 { requested = IPv4(request.u32(i + 2)) }
            i += 2 + length
        }
        let ciaddr = IPv4(request.u32(12))
        let reply: UInt8
        switch messageType {
        case 1: reply = 2 // DISCOVER → OFFER
        case 3: // REQUEST → ACK, or NAK for an address from some other network
            let asked = requested ?? ciaddr
            reply = asked == configuration.guest || asked == .any ? 5 : 6
        case 8: reply = 5 // INFORM
        default: return
        }

        var response = [UInt8](repeating: 0, count: 240)
        response[0] = 2
        response[1] = 1
        response[2] = 6
        response.replaceSubrange(4..<8, with: request[4..<8]) // xid
        response.replaceSubrange(10..<12, with: request[10..<12]) // flags
        if reply == 5 || reply == 2 {
            response.put32(messageType == 8 ? 0 : configuration.guest.value, at: 16)
        }
        response.put32(configuration.gateway.value, at: 20)
        response.replaceSubrange(28..<44, with: request[28..<44]) // chaddr
        response.put32(0x6382_5363, at: 236)
        func option(_ code: UInt8, _ bytes: [UInt8]) {
            response += [code, UInt8(bytes.count)] + bytes
        }
        func address(_ a: IPv4) -> [UInt8] { [UInt8(a.value >> 24), UInt8(a.value >> 16 & 0xFF), UInt8(a.value >> 8 & 0xFF), UInt8(a.value & 0xFF)] }
        option(53, [reply])
        option(54, address(configuration.gateway))
        if reply != 6 {
            if messageType != 8 { option(51, [0x00, 0x01, 0x51, 0x80]) } // 1 day
            option(1, address(configuration.netmask))
            option(3, address(configuration.gateway))
            option(6, address(configuration.gateway))
            option(26, [UInt8(configuration.mtu >> 8), UInt8(configuration.mtu & 0xFF)])
        }
        response.append(255)
        while response.count < 300 { response.append(0) }

        let packet = FrameBuilder.udp(from: configuration.gateway, port: 67, to: .broadcast, port: 68, payload: response)
        sendFrame(FrameBuilder.ethernet(to: .broadcast, from: gatewayMAC, type: EtherType.ipv4, payload: packet))
        if reply == 5, messageType == 3, !hasLease {
            hasLease = true
            log("guest network: \(configuration.guest) leased to \(guestMAC)")
            for waiter in leaseWaiters { waiter.resume() }
            leaseWaiters.removeAll()
        }
    }

    // MARK: Frames out

    func sendTCP(from source: IPv4, port sourcePort: UInt16, toPort: UInt16, seq: UInt32, ack: UInt32, flags: TCPFlags, window: UInt16, mss: UInt16?, windowScale: UInt8?, payload: ArraySlice<UInt8>) {
        let packet = FrameBuilder.tcp(
            from: source, port: sourcePort, to: configuration.guest, port: toPort,
            seq: seq, ack: ack, flags: flags, window: window, mss: mss, windowScale: windowScale, payload: payload
        )
        sendIP(packet)
    }

    func sendUDP(from source: IPv4, port sourcePort: UInt16, toPort: UInt16, payload: some Collection<UInt8>) {
        sendIP(FrameBuilder.udp(from: source, port: sourcePort, to: configuration.guest, port: toPort, payload: payload))
    }

    func sendIP(_ packet: [UInt8]) {
        var packet = packet
        ipID &+= 1
        packet.put16(ipID, at: 4)
        packet.put16(0, at: 10)
        packet.put16(finishChecksum(checksumSum(packet[0..<20])), at: 10)
        sendFrame(FrameBuilder.ethernet(to: guestMAC, from: gatewayMAC, type: EtherType.ipv4, payload: packet))
    }

    private func sendFrame(_ frame: [UInt8]) {
        guard !stopped else { return }
        if outbox.isEmpty, transmit(frame) { return }
        // Bounded: past this the guest isn't reading and TCP will retransmit anyway.
        guard outbox.count < 4096 else { return }
        outbox.append(frame)
        link?.setWriting(true)
    }

    /// `false` when the socket buffer is full.
    private func transmit(_ frame: [UInt8]) -> Bool {
        let sent = frame.withUnsafeBytes { send(fd, $0.baseAddress, $0.count, 0) }
        if sent >= 0 { return true }
        // The guest isn't attached or is gone; drop.
        return !(errno == EAGAIN || errno == ENOBUFS)
    }

    private func drainOutbox() {
        var sent = 0
        while sent < outbox.count, transmit(outbox[sent]) { sent += 1 }
        outbox.removeFirst(sent)
        guard outbox.isEmpty else { return }
        link?.setWriting(false)
        for flow in tcp.values { flow.pump() }
    }

    // MARK: Bookkeeping

    func remove(_ flow: TCPFlow) {
        if tcp[flow.key] === flow { tcp[flow.key] = nil }
    }

    /// Keeps a closed flow around to re-ACK retransmitted FINs, then drops it.
    func removeLater(_ flow: TCPFlow) {
        queue.asyncAfter(deadline: .now() + 2) { [weak self, weak flow] in
            guard let self, let flow else { return }
            remove(flow)
        }
    }

    func remove(_ flow: UDPFlow) {
        if udp[flow.key] === flow { udp[flow.key] = nil }
        flow.socket.close()
    }

    private func sweep() {
        let now = ContinuousClock.now
        for flow in udp.values where now - flow.lastActive > flow.idleTimeout {
            remove(flow)
        }
        icmp?.expire(now: now)
    }
}

public enum NetworkError: Error, CustomStringConvertible {
    case system(String, Int32)

    public var description: String {
        switch self {
        case let .system(call, code): "\(call): \(String(cString: strerror(code)))"
        }
    }
}


/// One guest UDP "connection" (guest port ↔ destination), backed by a connected host socket.
final class UDPFlow {
    struct Key: Hashable {
        var guestPort: UInt16
        var remote: IPv4
        var remotePort: UInt16
    }

    let key: Key
    let socket: SocketWatcher
    private unowned let network: GuestNetwork
    private(set) var lastActive = ContinuousClock.now
    let idleTimeout: Duration

    init?(key: Key, upstream: (IPv4, UInt16), network: GuestNetwork) {
        guard let fd = SocketOptions.makeSocket(type: SOCK_DGRAM) else { return nil }
        guard SocketOptions.connect(fd, to: upstream.0, port: upstream.1) else {
            close(fd)
            return nil
        }
        self.key = key
        self.network = network
        idleTimeout = key.remotePort == 53 ? .seconds(15) : .seconds(60)
        var receive: () -> Void = {}
        socket = SocketWatcher(fd: fd, queue: network.queue, onReadable: { receive() }, onWritable: {})
        receive = { [weak self] in self?.receive() }
        socket.setReading(true)
    }

    func send(_ payload: ArraySlice<UInt8>) {
        lastActive = .now
        _ = payload.withUnsafeBytes { Darwin.send(socket.fd, $0.baseAddress, $0.count, 0) }
    }

    private func receive() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        for _ in 0..<64 {
            let count = buffer.withUnsafeMutableBytes { recv(socket.fd, $0.baseAddress, $0.count, 0) }
            guard count >= 0 else { return }
            lastActive = .now
            // Replies come from where the guest sent to (the gateway, for DNS).
            network.sendUDP(from: key.remote, port: key.remotePort, toPort: key.guestPort, payload: buffer[..<count])
        }
    }
}

/// Echo requests through one unprivileged ICMP socket (`SOCK_DGRAM`/`IPPROTO_ICMP`).
final class ICMPRelay {
    let socket: SocketWatcher
    private unowned let network: GuestNetwork
    /// Destinations with outstanding requests; replies from anyone else are not the guest's.
    private var pending: [IPv4: ContinuousClock.Instant] = [:]

    init?(network: GuestNetwork) {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { return nil }
        SocketOptions.setNonBlocking(fd)
        self.network = network
        var receive: () -> Void = {}
        socket = SocketWatcher(fd: fd, queue: network.queue, onReadable: { receive() }, onWritable: {})
        receive = { [weak self] in self?.receive() }
        socket.setReading(true)
    }

    func send(_ message: [UInt8], to destination: IPv4) {
        pending[destination] = .now
        var address = destination.sockaddr
        _ = message.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socket.fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func receive() {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = buffer.withUnsafeMutableBytes { recv(socket.fd, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { return }
            var packet = Array(buffer[..<count])
            // macOS hands ICMP datagram sockets the IP header too.
            var source: IPv4?
            if packet[0] >> 4 == 4, let ip = IPv4Packet(packet) {
                source = ip.source
                packet = Array(ip.payload)
            }
            guard let source, packet.count >= 8, packet[0] == 0, pending[source] != nil else { continue }
            network.sendIP(FrameBuilder.icmp(from: source, to: network.configuration.guest, message: packet))
        }
    }

    func expire(now: ContinuousClock.Instant) {
        pending = pending.filter { now - $0.value < .seconds(30) }
    }
}
