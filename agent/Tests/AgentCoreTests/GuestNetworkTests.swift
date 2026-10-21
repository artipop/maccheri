import Darwin
import Foundation
import Network
import Testing
@testable import AgentCore

/// Plays the guest's side of the socketpair with hand-made frames.
final class FakeGuest {
    let network: GuestNetwork
    let mac = MACAddress([0x02, 0, 0, 0, 0, 0x01])
    var ip: IPv4 { network.configuration.guest }
    var gateway: IPv4 { network.configuration.gateway }
    let fd: Int32

    init(policy: EgressPolicy = EgressPolicy(allowed: [EgressPolicy.Range("127.0.0.0/8")!], blocksHostAddresses: false)) throws {
        var configuration = GuestNetwork.Configuration()
        configuration.policy = policy
        network = try GuestNetwork(guestMAC: mac, configuration: configuration)
        fd = network.guestFileHandle.fileDescriptor
        network.start()
    }

    deinit { network.stop() }

    func send(ip packet: [UInt8]) {
        let frame = FrameBuilder.ethernet(to: network.gatewayMAC, from: mac, type: EtherType.ipv4, payload: packet)
        _ = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
    }

    func send(raw frame: [UInt8]) {
        _ = frame.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
    }

    /// The next frame, or nil after `timeout`.
    func receive(timeout: Double = 2) -> [UInt8]? {
        var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&poller, 1, Int32(timeout * 1000)) > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 65536)
        let count = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
        return count > 0 ? Array(buffer[..<count]) : nil
    }

    /// The next TCP segment, skipping anything else.
    func receiveTCP(timeout: Double = 2) -> (IPv4Packet, TCPSegment)? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, let frame = receive(timeout: deadline.timeIntervalSinceNow) {
            guard frame.u16(12) == EtherType.ipv4, let packet = IPv4Packet(Array(frame[14...])), packet.proto == IPProtocolNumber.tcp,
                  let segment = TCPSegment(packet.payload) else { continue }
            return (packet, segment)
        }
        return nil
    }

    func tcp(to destination: IPv4, port: UInt16, from sourcePort: UInt16, seq: UInt32, ack: UInt32, flags: TCPFlags, window: UInt16 = 65535, windowScale: UInt8? = nil, payload: [UInt8] = []) {
        send(ip: FrameBuilder.tcp(
            from: ip, port: sourcePort, to: destination, port: port, seq: seq, ack: ack, flags: flags, window: window,
            mss: flags.contains(.syn) ? 1460 : nil, windowScale: windowScale, payload: payload
        ))
    }
}

/// A loopback TCP server; `handler` gets each accepted connection.
func loopbackServer(_ handler: @escaping @Sendable (NWConnection) -> Void) async throws -> NWListener {
    let queue = DispatchQueue(label: "server")
    let listener = try NWListener(using: .tcp, on: .any)
    listener.newConnectionHandler = { connection in
        connection.start(queue: queue)
        handler(connection)
    }
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
        listener.stateUpdateHandler = { state in
            if case .ready = state { c.resume() }
            if case .failed(let e) = state { c.resume(throwing: e) }
        }
        listener.start(queue: queue)
    }
    return listener
}

func echo(_ connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, _ in
        if let data, !data.isEmpty { connection.send(content: data, completion: .contentProcessed { _ in }) }
        if done { connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in }) } else { echo(connection) }
    }
}

/// Serialized: the fake guest blocks in poll(2), which would starve the cooperative pool.
@Suite(.serialized) struct GuestNetworkTests {
    @Test func policyRefusesLocalNetworks() {
        let policy = EgressPolicy.internetOnly
        for blocked in ["192.168.1.1", "10.0.0.1", "172.16.5.4", "169.254.1.1", "127.0.0.1", "100.100.100.100", "224.0.0.251", "255.255.255.255", "0.0.0.0"] {
            #expect(!policy.permits(IPv4(blocked)!), "\(blocked)")
        }
        for open in ["1.1.1.1", "140.82.112.3", "17.253.144.10", "172.32.0.1"] {
            #expect(policy.permits(IPv4(open)!), "\(open)")
        }
    }

    @Test func answersDHCPAndARP() throws {
        let guest = try FakeGuest()
        var discover = [UInt8](repeating: 0, count: 240)
        discover[0] = 1
        discover[1] = 1
        discover[2] = 6
        discover.put32(0xDEAD_BEEF, at: 4)
        discover.replaceSubrange(28..<34, with: guest.mac.bytes)
        discover.put32(0x6382_5363, at: 236)
        discover += [53, 1, 1, 255]
        let packet = FrameBuilder.udp(from: .any, port: 68, to: .broadcast, port: 67, payload: discover)
        guest.send(raw: FrameBuilder.ethernet(to: .broadcast, from: guest.mac, type: EtherType.ipv4, payload: packet))

        let frame = try #require(guest.receive())
        let ip = try #require(IPv4Packet(Array(frame[14...])))
        let udp = try #require(UDPDatagram(ip.payload))
        let offer = Array(udp.payload)
        #expect(udp.destinationPort == 68)
        #expect(offer.u32(4) == 0xDEAD_BEEF)
        #expect(IPv4(offer.u32(16)) == guest.ip)
        #expect(offer[240..<243] == [53, 1, 2])

        var arp = [UInt8](repeating: 0, count: 28)
        arp.put16(1, at: 0)
        arp.put16(EtherType.ipv4, at: 2)
        arp[4] = 6
        arp[5] = 4
        arp.put16(1, at: 6)
        arp.replaceSubrange(8..<14, with: guest.mac.bytes)
        arp.put32(guest.ip.value, at: 14)
        arp.put32(guest.gateway.value, at: 24)
        guest.send(raw: FrameBuilder.ethernet(to: .broadcast, from: guest.mac, type: EtherType.arp, payload: arp))
        let reply = try #require(guest.receive())
        #expect(reply.u16(12) == EtherType.arp)
        #expect(Array(reply[22..<28]) == guest.network.gatewayMAC.bytes)

        // Nobody answers for other addresses, e.g. the owner's router.
        arp.put32(IPv4(192, 168, 1, 1).value, at: 24)
        guest.send(raw: FrameBuilder.ethernet(to: .broadcast, from: guest.mac, type: EtherType.arp, payload: arp))
        #expect(guest.receive(timeout: 0.3) == nil)
    }

    @Test func refusesTCPToLocalNetwork() throws {
        let guest = try FakeGuest(policy: .internetOnly)
        guest.tcp(to: IPv4(192, 168, 1, 1), port: 80, from: 50000, seq: 1000, ack: 0, flags: [.syn])
        let (_, reset) = try #require(guest.receiveTCP())
        #expect(reset.flags.contains(.rst))
        #expect(reset.ack == 1001)

        guest.tcp(to: guest.gateway, port: 22, from: 50001, seq: 5, ack: 0, flags: [.syn])
        #expect(try #require(guest.receiveTCP()).1.flags.contains(.rst))
    }

    @Test func relaysTCPBothWays() async throws {
        let server = try await loopbackServer(echo)
        defer { server.cancel() }
        let guest = try FakeGuest()
        let localhost = IPv4(127, 0, 0, 1)
        let port = server.port!.rawValue

        guest.tcp(to: localhost, port: port, from: 50000, seq: 100, ack: 0, flags: [.syn], windowScale: 7)
        let (_, synAck) = try #require(guest.receiveTCP())
        #expect(synAck.flags == [.syn, .ack])
        #expect(synAck.ack == 101)
        #expect(synAck.windowScale == TCPFlow.ourWindowScale)
        var theirs = synAck.seq &+ 1
        guest.tcp(to: localhost, port: port, from: 50000, seq: 101, ack: theirs, flags: [.ack], window: 1024)

        let message = Array("hello through the NAT".utf8)
        guest.tcp(to: localhost, port: port, from: 50000, seq: 101, ack: theirs, flags: [.ack, .psh], window: 1024, payload: message)
        var echoed: [UInt8] = []
        while echoed.count < message.count {
            let (_, segment) = try #require(guest.receiveTCP())
            if !segment.payload.isEmpty {
                #expect(segment.seq == theirs)
                echoed += segment.payload
                theirs &+= UInt32(segment.payload.count)
            }
        }
        #expect(echoed == message)

        // Guest closes; the server echoes the close back.
        let mine = 101 &+ UInt32(message.count)
        guest.tcp(to: localhost, port: port, from: 50000, seq: mine, ack: theirs, flags: [.ack, .fin], window: 1024)
        var sawFIN = false
        while !sawFIN, let (_, segment) = guest.receiveTCP() {
            if segment.flags.contains(.fin) {
                sawFIN = true
                #expect(segment.ack == mine &+ 1)
                guest.tcp(to: localhost, port: port, from: 50000, seq: mine &+ 1, ack: segment.seq &+ 1, flags: [.ack], window: 1024)
            }
        }
        #expect(sawFIN)
    }

    /// 3 MB from the host to a guest with a small window: segments, ACK clocking and window updates.
    @Test func streamsBulkDataWithinTheGuestWindow() async throws {
        let total = 3 << 20
        let blob = Data((0..<total).map { UInt8(truncatingIfNeeded: $0 * 7) })
        let server = try await loopbackServer { connection in
            connection.send(content: blob, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in })
        }
        defer { server.cancel() }
        let guest = try FakeGuest()
        let localhost = IPv4(127, 0, 0, 1)
        let port = server.port!.rawValue

        guest.tcp(to: localhost, port: port, from: 50100, seq: 0, ack: 0, flags: [.syn], windowScale: 0)
        let (_, synAck) = try #require(guest.receiveTCP())
        var next = synAck.seq &+ 1
        let window: UInt16 = 32 << 10
        guest.tcp(to: localhost, port: port, from: 50100, seq: 1, ack: next, flags: [.ack], window: window)

        var received = [UInt8]()
        received.reserveCapacity(total)
        var unacked = 0
        while true {
            guard let (_, segment) = guest.receiveTCP(timeout: 5) else { break }
            #expect(Int(segment.seq &- next) <= Int(window), "sent beyond the window")
            if segment.seq == next {
                received += segment.payload
                next &+= UInt32(segment.payload.count)
                unacked += segment.payload.count
            }
            if segment.flags.contains(.fin) {
                next &+= 1
                guest.tcp(to: localhost, port: port, from: 50100, seq: 1, ack: next, flags: [.ack], window: window)
                break
            }
            if unacked >= Int(window) / 2 {
                guest.tcp(to: localhost, port: port, from: 50100, seq: 1, ack: next, flags: [.ack], window: window)
                unacked = 0
            }
        }
        #expect(received.count == total)
        #expect(Data(received) == blob)
    }

    @Test func probeSeesListeningAndClosedPorts() async throws {
        let guest = try FakeGuest()
        // On its own thread: it blocks reading frames. First probe: the port is closed; second: it accepts.
        Thread {
            for accept in [false, true] {
                guard let (_, syn) = guest.receiveTCP() else { return }
                #expect(syn.flags == [.syn])
                if accept {
                    guest.tcp(to: guest.gateway, port: syn.sourcePort, from: syn.destinationPort, seq: 9000, ack: syn.seq &+ 1, flags: [.syn, .ack])
                } else {
                    guest.tcp(to: guest.gateway, port: syn.sourcePort, from: syn.destinationPort, seq: 0, ack: syn.seq &+ 1, flags: [.rst, .ack])
                }
            }
        }.start()
        #expect(await guest.network.probe(port: 7300) == false)
        #expect(await guest.network.probe(port: 7300) == true)
    }

    @Test func probeTimesOutWhenTheGuestIsSilent() async throws {
        let guest = try FakeGuest()
        let started = ContinuousClock.now
        #expect(await guest.network.probe(port: 7300) == false)
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func forwardsLoopbackConnectionsIntoTheGuest() async throws {
        let guest = try FakeGuest()
        let port = try guest.network.forward(guestPort: 7300)

        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        client.start(queue: DispatchQueue(label: "client"))
        defer { client.cancel() }

        let (_, syn) = try #require(guest.receiveTCP())
        #expect(syn.destinationPort == 7300)
        let peerPort = syn.sourcePort
        let mySeq: UInt32 = 777
        guest.tcp(to: guest.gateway, port: peerPort, from: 7300, seq: mySeq, ack: syn.seq &+ 1, flags: [.syn, .ack], windowScale: 3)
        let (_, ack) = try #require(guest.receiveTCP())
        #expect(ack.flags == [.ack])
        var theirs = syn.seq &+ 1

        // Guest → client.
        let greeting = Array("frame".utf8)
        guest.tcp(to: guest.gateway, port: peerPort, from: 7300, seq: mySeq &+ 1, ack: theirs, flags: [.ack, .psh], payload: greeting)
        let got: Data = try await withCheckedThrowingContinuation { c in
            client.receive(minimumIncompleteLength: greeting.count, maximumLength: 100) { data, _, _, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: data ?? Data()) }
            }
        }
        #expect(Array(got) == greeting)

        // Client → guest.
        client.send(content: Data("touch".utf8), completion: .contentProcessed { _ in })
        var payload: [UInt8] = []
        while payload.isEmpty, let (_, segment) = guest.receiveTCP() {
            payload += segment.payload
            if !segment.payload.isEmpty { theirs = segment.seq &+ UInt32(segment.payload.count) }
        }
        #expect(payload == Array("touch".utf8))
        _ = theirs
    }

    @Test func relaysUDP() async throws {
        // A loopback UDP echo socket.
        let server = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(server) }
        var address = IPv4(127, 0, 0, 1).sockaddr
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &length) } }
        let port = UInt16(bigEndian: address.sin_port)
        let echoThread = Thread {
            var buffer = [UInt8](repeating: 0, count: 2048)
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(server, bytes.baseAddress, bytes.count, 0, $0, &fromLength) } }
            }
            guard count > 0 else { return }
            _ = buffer.withUnsafeBytes { bytes in
                withUnsafePointer(to: &from) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(server, bytes.baseAddress, count, 0, $0, fromLength) } }
            }
        }
        echoThread.start()

        let guest = try FakeGuest()
        guest.send(ip: FrameBuilder.udp(from: guest.ip, port: 5353, to: IPv4(127, 0, 0, 1), port: port, payload: Array("ping".utf8)))
        let frame = try #require(guest.receive())
        let ip = try #require(IPv4Packet(Array(frame[14...])))
        let udp = try #require(UDPDatagram(ip.payload))
        #expect(ip.source == IPv4(127, 0, 0, 1))
        #expect(udp.sourcePort == port)
        #expect(udp.destinationPort == 5353)
        #expect(Array(udp.payload) == Array("ping".utf8))
    }

    @Test func dropsSpoofedSources() throws {
        let guest = try FakeGuest()
        guest.send(ip: FrameBuilder.tcp(from: IPv4(10, 233, 0, 9), port: 1, to: IPv4(127, 0, 0, 1), port: 2, seq: 0, ack: 0, flags: [.syn], window: 100))
        #expect(guest.receive(timeout: 0.3) == nil)
    }
}
