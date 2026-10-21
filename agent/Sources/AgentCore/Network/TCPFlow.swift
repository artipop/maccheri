import Darwin
import Foundation

/// One TCP connection between the guest and a host socket. The guest's end is a real TCP stack;
/// ours is just enough TCP to talk to it over a lossless-but-bounded virtual link: in-order
/// receive (out-of-order segments are dropped and re-ACKed, the guest retransmits), go-back-N
/// retransmission, window scaling, no SACK or timestamps. The host end is an ordinary socket,
/// so the kernel does real TCP towards the internet.
///
/// Everything here runs on ``GuestNetwork``'s queue.
final class TCPFlow: @unchecked Sendable {
    struct Key: Hashable {
        var guestPort: UInt16
        /// The address and port the guest thinks it talks to.
        var remote: IPv4
        var remotePort: UInt16
    }

    enum Origin {
        /// The guest connected out; the host socket connects to the same destination.
        case guest
        /// A host client (port forward) connected in; we open a connection to the guest.
        case host
        /// Only checking that the guest accepts connections on a port.
        case probe((Bool) -> Void)
    }

    enum State {
        /// Guest SYN seen, host socket still connecting.
        case connecting
        /// SYN-ACK sent to the guest, waiting for its ACK.
        case synReceived
        /// SYN sent to the guest, waiting for its SYN-ACK.
        case synSent
        case established
        /// Both directions done; lingers briefly to re-ACK a retransmitted FIN.
        case closed
    }

    static let receiveCapacity = 1 << 20
    static let sendCapacity = 1 << 20
    static let ourWindowScale: UInt8 = 5
    static let minRTO = 200
    static let maxRTO = 2000
    static let maxRetries = 10

    let key: Key
    let origin: Origin
    private unowned let network: GuestNetwork
    private(set) var state: State
    private var socket: SocketWatcher?

    private let iss = UInt32.random(in: 0...UInt32.max)
    private var sndUna: UInt32
    private var sndNxt: UInt32
    private var rcvNxt: UInt32 = 0
    private var guestWindow: UInt32 = 65535
    private var guestScale: UInt8 = 0
    private var scaling = false
    private var mss: Int

    /// Bytes read from the host, starting at `sndUna`.
    private var sendBuffer = ByteQueue()
    /// Bytes from the guest not yet written to the host socket.
    private var toHost = ByteQueue()
    private var hostEOF = false
    private var finSent = false
    private var finAcked = false
    private var guestFIN = false
    private var hostWriteShut = false

    private var dupAcks = 0
    private var rto = TCPFlow.minRTO
    private var retries = 0
    private var timer: (any DispatchSourceTimer)?
    private var lastAdvertised = 0
    var needsAck = false

    var isClosed: Bool { state == .closed }

    /// Guest-initiated: called for the guest's SYN; starts connecting the host socket.
    init?(guestSYN segment: TCPSegment, key: Key, network: GuestNetwork) {
        guard let fd = SocketOptions.makeSocket(type: SOCK_STREAM) else { return nil }
        self.key = key
        self.network = network
        origin = .guest
        state = .connecting
        sndUna = iss
        sndNxt = iss
        rcvNxt = segment.seq &+ 1
        guestWindow = UInt32(segment.window)
        if let scale = segment.windowScale {
            scaling = true
            guestScale = min(scale, 14)
        }
        mss = min(Int(segment.mss ?? 536), network.maxSegmentSize)
        guard SocketOptions.connect(fd, to: key.remote, port: key.remotePort) else {
            Darwin.close(fd)
            return nil
        }
        socket = SocketWatcher(fd: fd, queue: network.queue, onReadable: { [unowned self] in hostReadable() }, onWritable: { [unowned self] in hostWritable() })
        socket?.setWriting(true)
    }

    /// Host-initiated: `fd` is an accepted client socket, or nil for a probe.
    init(connectingTo key: Key, fd: Int32?, origin: Origin, network: GuestNetwork) {
        self.key = key
        self.network = network
        self.origin = origin
        state = .synSent
        sndUna = iss
        sndNxt = iss &+ 1
        mss = network.maxSegmentSize
        if let fd {
            SocketOptions.setNonBlocking(fd)
            SocketOptions.set(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
            SocketOptions.set(fd, IPPROTO_TCP, TCP_NODELAY, 1)
            socket = SocketWatcher(fd: fd, queue: network.queue, onReadable: { [unowned self] in hostReadable() }, onWritable: { [unowned self] in hostWritable() })
        }
        sendSYN()
    }

    // MARK: Guest → us

    func handle(_ segment: TCPSegment) {
        let flags = segment.flags
        switch state {
        case .connecting:
            if flags.contains(.rst) { return abort(notifyGuest: false) }
            // Retransmitted SYNs wait for the host connect.
            return

        case .synSent:
            if flags.contains(.rst) {
                if flags.contains(.ack), segment.ack == sndNxt { abort(notifyGuest: false) }
                return
            }
            guard flags.contains([.syn, .ack]), segment.ack == sndNxt else { return }
            rcvNxt = segment.seq &+ 1
            guestWindow = UInt32(segment.window)
            if let scale = segment.windowScale {
                scaling = true
                guestScale = min(scale, 14)
            }
            mss = min(Int(segment.mss ?? 536), network.maxSegmentSize)
            sndUna = sndNxt
            stopTimer()
            if case let .probe(done) = origin {
                emit(seq: sndNxt, flags: [.rst])
                state = .closed
                network.remove(self)
                return done(true)
            }
            state = .established
            emit(seq: sndNxt, flags: [.ack])
            socket?.setReading(true)
            return

        case .synReceived:
            if flags.contains(.rst) { return abort(notifyGuest: false) }
            if flags.contains(.syn) { return sendSYN() }
            guard flags.contains(.ack), segment.ack == sndNxt else { return }
            sndUna = sndNxt
            stopTimer()
            retries = 0
            state = .established
            socket?.setReading(true)
            guestWindow = UInt32(segment.window) << (scaling ? UInt32(guestScale) : 0)
            receive(segment)
            pump()

        case .established:
            if flags.contains(.rst) { return abort(notifyGuest: false) }
            if flags.contains(.syn) {
                needsAck = true
                return
            }
            if flags.contains(.ack) { processAck(segment) }
            receive(segment)
            pump()
            finishIfDone()

        case .closed:
            if flags.contains(.rst) { return network.remove(self) }
            if !segment.payload.isEmpty || flags.contains(.fin) { needsAck = true }
        }
    }

    private func processAck(_ segment: TCPSegment) {
        let ack = segment.ack
        let window = UInt32(segment.window) << (scaling ? UInt32(guestScale) : 0)
        // Any ACK means the guest is alive; only stalls without one count towards giving up.
        retries = 0
        if seqGreater(ack, sndNxt) {
            needsAck = true
            return
        }
        if seqGreater(ack, sndUna) {
            var acked = Int(ack &- sndUna)
            if finSent, ack == sndNxt {
                finAcked = true
                acked -= 1
            }
            sendBuffer.removeFirst(min(acked, sendBuffer.count))
            sndUna = ack
            dupAcks = 0
            rto = Self.minRTO
            guestWindow = window
            if sndUna == sndNxt { stopTimer() } else { restartTimer() }
            if !hostEOF, sendBuffer.count < Self.sendCapacity { socket?.setReading(true) }
        } else if ack == sndUna {
            let duplicate = segment.payload.isEmpty && !segment.flags.contains(.fin) && window == guestWindow && sndNxt != sndUna
            guestWindow = window
            if duplicate {
                dupAcks += 1
                if dupAcks == 3 { goBack() }
            }
        }
    }

    private func receive(_ segment: TCPSegment) {
        var payload = segment.payload
        var seq = segment.seq
        let fin = segment.flags.contains(.fin)
        guard !payload.isEmpty || fin else { return }
        if guestFIN {
            needsAck = true
            return
        }
        if seqLess(seq, rcvNxt) {
            let skip = Int(rcvNxt &- seq)
            guard skip <= payload.count else {
                needsAck = true
                return
            }
            payload = payload.dropFirst(skip)
            seq = rcvNxt
        }
        needsAck = true
        // Out of order: drop; the duplicate ACK makes the guest retransmit.
        guard seq == rcvNxt else { return }
        let take = min(payload.count, Self.receiveCapacity - toHost.count)
        if take > 0 {
            toHost.append(contentsOf: payload.prefix(take))
            rcvNxt &+= UInt32(take)
            flushToHost()
        }
        if fin, take == payload.count {
            rcvNxt &+= 1
            guestFIN = true
            flushToHost()
        }
    }

    // MARK: Host socket

    private func hostWritable() {
        guard let socket else { return }
        if state == .connecting {
            socket.setWriting(false)
            let error = SocketOptions.pendingError(socket.fd)
            guard error == 0 else {
                network.log("tcp \(key.remote):\(key.remotePort): \(String(cString: strerror(error)))")
                return abort(notifyGuest: true)
            }
            state = .synReceived
            sndNxt = iss &+ 1
            return sendSYN()
        }
        flushToHost()
    }

    private func flushToHost() {
        guard let socket else { return }
        var failed = false
        toHost.drain { buffer in
            let written = Darwin.write(socket.fd, buffer.baseAddress, buffer.count)
            if written < 0 {
                if errno != EAGAIN { failed = true }
                return 0
            }
            return written
        }
        if failed { return abort(notifyGuest: true) }
        socket.setWriting(!toHost.isEmpty)
        if toHost.isEmpty, guestFIN, !hostWriteShut {
            hostWriteShut = true
            shutdown(socket.fd, SHUT_WR)
            finishIfDone()
        }
        // Tell the guest promptly once the window has opened up again.
        let window = Self.receiveCapacity - toHost.count
        if state == .established, window - lastAdvertised >= 64 << 10 || (lastAdvertised < mss && window >= mss) {
            emit(seq: sndNxt, flags: [.ack])
        }
    }

    private func hostReadable() {
        guard let socket, state == .established, !hostEOF else { return }
        let room = Self.sendCapacity - sendBuffer.count
        guard room > 0 else { return socket.setReading(false) }
        var buffer = [UInt8](repeating: 0, count: min(room, 256 << 10))
        let count = buffer.withUnsafeMutableBytes { Darwin.read(socket.fd, $0.baseAddress, $0.count) }
        if count > 0 {
            sendBuffer.append(contentsOf: buffer[..<count])
        } else if count == 0 {
            hostEOF = true
            socket.setReading(false)
        } else if errno != EAGAIN {
            return abort(notifyGuest: true)
        }
        pump()
        finishIfDone()
    }

    // MARK: Us → guest

    /// Sends what the guest's window and the link allow.
    func pump(force: Bool = false) {
        guard state == .established else { return }
        var force = force
        while !finSent, !network.linkBusy {
            let inFlight = Int(sndNxt &- sndUna)
            let unsent = sendBuffer.count - inFlight
            if unsent > 0 {
                var room = Int(guestWindow) - inFlight
                if room <= 0 {
                    // Zero window: the retransmit timer keeps probing with one byte.
                    guard force, inFlight == 0 else {
                        armTimer()
                        break
                    }
                    room = 1
                }
                let length = min(unsent, mss, room)
                emit(seq: sndNxt, flags: [.ack, .psh], payload: sendBuffer.slice(from: inFlight, length: length))
                sndNxt &+= UInt32(length)
                armTimer()
                force = false
            } else if hostEOF {
                emit(seq: sndNxt, flags: [.ack, .fin])
                sndNxt &+= 1
                finSent = true
                armTimer()
            } else {
                break
            }
        }
    }

    /// Retransmits everything from the oldest unacknowledged byte.
    private func goBack() {
        sndNxt = sndUna
        if finSent, !finAcked { finSent = false }
        dupAcks = 0
        pump(force: true)
    }

    private func sendSYN() {
        switch state {
        case .synSent:
            emit(seq: iss, flags: [.syn], mss: UInt16(network.maxSegmentSize), windowScale: Self.ourWindowScale, ack: 0)
        case .synReceived:
            emit(seq: iss, flags: [.syn, .ack], mss: UInt16(network.maxSegmentSize), windowScale: scaling ? Self.ourWindowScale : nil)
        default:
            return
        }
        armTimer()
    }

    func emit(seq: UInt32, flags: TCPFlags, payload: ArraySlice<UInt8> = [], mss: UInt16? = nil, windowScale: UInt8? = nil, ack: UInt32? = nil) {
        let window = Self.receiveCapacity - toHost.count
        let advertised: UInt16
        if flags.contains(.syn) {
            advertised = UInt16(min(window, 65535))
        } else {
            advertised = UInt16(min(window >> (scaling ? Int(Self.ourWindowScale) : 0), 65535))
        }
        lastAdvertised = window
        needsAck = false
        network.sendTCP(
            from: key.remote, port: key.remotePort, toPort: key.guestPort,
            seq: seq, ack: ack ?? rcvNxt, flags: flags, window: advertised, mss: mss, windowScale: windowScale, payload: payload
        )
    }

    func emitAck() {
        emit(seq: sndNxt, flags: [.ack])
    }

    // MARK: Timer

    private func armTimer() {
        guard timer == nil else { return }
        restartTimer()
    }

    private func restartTimer() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: network.queue)
        timer.schedule(deadline: .now() + .milliseconds(rto))
        timer.setEventHandler { [unowned self] in timerFired() }
        timer.resume()
        self.timer = timer
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func timerFired() {
        timer = nil
        retries += 1
        let limit: Int
        if case .probe = origin { limit = 2 } else { limit = state == .established ? Self.maxRetries : 5 }
        guard retries <= limit else {
            if case let .probe(done) = origin {
                state = .closed
                network.remove(self)
                return done(false)
            }
            network.log("tcp \(key.remote):\(key.remotePort) ↔ guest:\(key.guestPort): guest stopped answering")
            return abort(notifyGuest: true)
        }
        rto = min(rto * 2, Self.maxRTO)
        switch state {
        case .synSent, .synReceived:
            sendSYN()
        case .established:
            if sndNxt != sndUna || sendBuffer.count > 0 || (hostEOF && !finAcked) { goBack() }
        case .connecting, .closed:
            break
        }
    }

    // MARK: Teardown

    private func finishIfDone() {
        guard state == .established, guestFIN, hostWriteShut, hostEOF, finAcked else { return }
        state = .closed
        stopTimer()
        socket?.close()
        socket = nil
        network.removeLater(self)
    }

    /// Resets both ends. `notifyGuest` sends RST to the guest (it would otherwise keep waiting).
    func abort(notifyGuest: Bool) {
        if notifyGuest {
            switch state {
            case .connecting: emit(seq: 0, flags: [.rst, .ack])
            case .synSent: emit(seq: sndNxt, flags: [.rst], ack: 0)
            default: emit(seq: sndNxt, flags: [.rst, .ack])
            }
        }
        state = .closed
        stopTimer()
        socket?.close(reset: true)
        socket = nil
        if case let .probe(done) = origin { done(false) }
        network.remove(self)
    }

    /// Sends the RST|ACK a closed port answers a SYN with.
    static func refuse(_ segment: TCPSegment, key: Key, network: GuestNetwork) {
        let ack = segment.seq &+ UInt32(segment.payload.count) &+ (segment.flags.contains(.syn) ? 1 : 0) &+ (segment.flags.contains(.fin) ? 1 : 0)
        let seq = segment.flags.contains(.ack) ? segment.ack : 0
        network.sendTCP(from: key.remote, port: key.remotePort, toPort: key.guestPort, seq: seq, ack: ack, flags: segment.flags.contains(.ack) ? [.rst] : [.rst, .ack], window: 0, mss: nil, windowScale: nil, payload: [])
    }
}

@inline(__always) func seqLess(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) < 0 }
@inline(__always) func seqGreater(_ a: UInt32, _ b: UInt32) -> Bool { Int32(bitPattern: a &- b) > 0 }
