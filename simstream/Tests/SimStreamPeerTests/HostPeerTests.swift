import Foundation
import LibDataChannel
import MaccheriProtocol
import Network
import SimStreamProtocol
import Testing
@testable import SimStreamPeer

/// A one-client simstream stand-in: sends `hello` on connect, records what the client sends.
final class FakeGuest: @unchecked Sendable {
    let listener: NWListener
    let queue = DispatchQueue(label: "fake-guest")
    private var connection: NWConnection?
    private var reader = MessageReader()
    private let lock = NSLock()
    private var _received: [SimStreamMessage] = []
    var received: [SimStreamMessage] { lock.withLock { _received } }
    let hello = Hello(screenWidth: 1206, screenHeight: 2622, videoWidth: 1206, videoHeight: 2622, codec: 0x6176_6331, deviceID: "TEST", deviceName: "iPhone Test")

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.connection = connection
            connection.start(queue: self.queue)
            self.send(.hello(self.hello))
            self.receive(connection)
        }
    }

    func start() async throws -> UInt16 {
        listener.start(queue: queue)
        for _ in 0..<100 {
            if let port = listener.port?.rawValue, port != 0 { return port }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CancellationError()
    }

    func send(_ message: SimStreamMessage) {
        connection?.send(content: message.encoded(), completion: .idempotent)
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data, let messages = try? self.reader.append(data) {
                self.lock.withLock { self._received += messages }
            }
            if !done, error == nil { self.receive(connection) }
        }
    }
}

/// The browser's side, played by libdatachannel: answers the offer and collects channel messages.
final class FakeViewer: @unchecked Sendable {
    let pc: RTCPeerConnection
    let signaling: LocalSignaling
    private let lock = NSLock()
    private var channels: [String: RTCChannel] = [:]
    private var _messages: [String: [SimStreamMessage]] = [:]

    init(signaling: LocalSignaling) throws {
        self.signaling = signaling
        pc = try RTCPeerConnection(.init())
        pc.onLocalDescription = { sdp, type in
            Task { try? await signaling.send(type == "answer" ? .answer(sdp: sdp) : .offer(sdp: sdp)) }
        }
        pc.onLocalCandidate = { candidate, mid in
            Task { try? await signaling.send(.candidate(candidate: candidate, sdpMid: mid, sdpMLineIndex: nil)) }
        }
        pc.onDataChannel = { [weak self] channel, label in
            guard let self else { return }
            channel.onMessage = { [weak self] data in
                guard let self, let message = try? SimStreamMessage(body: data) else { return }
                self.lock.withLock { self._messages[label, default: []].append(message) }
            }
            self.lock.withLock { self.channels[label] = channel }
        }
        _ = Task { [pc] in
            while let message = try await signaling.receive() {
                switch message {
                case .offer(let sdp):
                    try pc.setRemoteDescription(sdp: sdp, type: "offer")
                    try pc.setLocalDescription("answer")
                case .candidate(let candidate, let mid, _):
                    try pc.addRemoteCandidate(candidate, mid: mid)
                default:
                    break
                }
            }
        }
    }

    func close() {
        lock.withLock { channels.values }.forEach { $0.close() }
        pc.close()
    }

    func messages(_ label: String) -> [SimStreamMessage] { lock.withLock { _messages[label] ?? [] } }

    func send(_ message: SimStreamMessage, on label: String = "control") {
        lock.withLock { channels[label] }?.send(message.encodedBody())
    }

    func waitFor(_ what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { Issue.record("timed out waiting for \(what)"); throw CancellationError() }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}

@Suite(.serialized)
struct HostPeerTests {
    @Test func relaysBetweenViewerAndGuestOverDataChannels() async throws {
        let guest = try FakeGuest()
        let port = try await guest.start()
        let (hostSide, viewerSide) = LocalSignaling.pair()
        let viewer = try FakeViewer(signaling: viewerSide)
        var options = HostPeer.Options()
        options.videoChunkSize = 1000
        let peer = HostPeer(transport: hostSide, iceServers: [], sessionID: UUID(), options: options) {
            NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        }
        let run = Task { try await peer.run() }

        // The guest's hello reaches the viewer once `control` opens.
        try await viewer.waitFor("hello") { viewer.messages("control").contains(.hello(guest.hello)) }

        // No video until the viewer picks a transport; then the guest is asked for a keyframe.
        viewer.send(.streamConfig(StreamConfig(video: .dataChannel)))
        try await viewer.waitFor("keyframe request") { guest.received.contains(.requestKeyframe) }

        // A delta frame before the keyframe is dropped; the keyframe and what follows arrive sliced.
        let delta = VideoFrame(isKeyframe: false, inputAck: 0, payload: Data(repeating: 1, count: 500))
        let key = VideoFrame(isKeyframe: true, inputAck: 3, ackAgeMicros: 7000, captureMicros: 1_000_000,
                             parameterSets: [Data([0x67, 1, 2]), Data([0x68, 3])], payload: Data((0..<5000).map { UInt8($0 & 0xff) }))
        guest.send(.video(delta))
        guest.send(.video(key))
        guest.send(.video(delta))
        try await viewer.waitFor("video chunks") { viewer.messages("video").count >= 7 }
        let chunks = viewer.messages("video").compactMap { if case .videoChunk(let c) = $0 { c } else { nil } }
        let frames = Dictionary(grouping: chunks, by: \.frame).sorted { $0.key < $1.key }.map { _, chunks in
            try? SimStreamMessage(body: chunks.sorted { $0.index < $1.index }.reduce(Data()) { $0 + $1.bytes })
        }
        #expect(frames == [.video(key), .video(delta)])

        // Input goes to the guest unchanged; the host keeps streamConfig to itself.
        let touch = Touch(id: 1, phase: .began, x: 0.5, y: 0.25)
        viewer.send(.touch(touch))
        viewer.send(.key(KeyEvent(usage: 4, down: true)))
        try await viewer.waitFor("input at the guest") { guest.received.contains(.key(KeyEvent(usage: 4, down: true))) }
        #expect(guest.received.contains(.touch(touch)))
        #expect(!guest.received.contains { if case .streamConfig = $0 { true } else { false } })

        // Guest replies come back on control.
        guest.send(.installStatus(InstallStatus(state: .launched, message: "dev.maccheri.probe")))
        try await viewer.waitFor("install status") { viewer.messages("control").contains(.installStatus(InstallStatus(state: .launched, message: "dev.maccheri.probe"))) }

        try await viewerSide.send(.bye(reason: "done"))
        #expect(try await run.value == .bye("done"))
        viewer.close()
    }

    @Test func videoTrackModeSendsFrameInfo() async throws {
        let guest = try FakeGuest()
        let port = try await guest.start()
        let (hostSide, viewerSide) = LocalSignaling.pair()
        let viewer = try FakeViewer(signaling: viewerSide)
        let peer = HostPeer(transport: hostSide, iceServers: [], sessionID: UUID()) {
            NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        }
        let run = Task { try await peer.run() }
        try await viewer.waitFor("hello") { !viewer.messages("control").isEmpty }
        viewer.send(.streamConfig(StreamConfig(video: .track)))
        try await viewer.waitFor("keyframe request") { guest.received.contains(.requestKeyframe) }
        guest.send(.video(VideoFrame(isKeyframe: true, inputAck: 9, ackAgeMicros: 1, encodeMicros: 2, captureMicros: 2_000_000, payload: Data([0, 0, 0, 1, 0x65]))))
        let info = FrameInfo(rtpTimestamp: HostPeer.rtpTimestamp(captureMicros: 2_000_000), isKeyframe: true, inputAck: 9, ackAgeMicros: 1, encodeMicros: 2)
        try await viewer.waitFor("frame info") { viewer.messages("control").contains(.frameInfo(info)) }
        #expect(info.rtpTimestamp == 180_000)
        peer.stop(reason: "test")
        #expect(try await run.value == .stopped("test"))
        #expect(hostSide.sent.last == .bye(reason: "test"))
        viewer.close()
    }

    @Test func endsWhenTheViewerNeverComes() async throws {
        let guest = try FakeGuest()
        let port = try await guest.start()
        let (hostSide, _) = LocalSignaling.pair()
        var options = HostPeer.Options()
        options.connectTimeout = 0.3
        let peer = HostPeer(transport: hostSide, iceServers: [], sessionID: UUID(), options: options) {
            NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        }
        #expect(try await peer.run() == .connectTimeout)
        #expect(hostSide.sent.first.map { if case .offer = $0 { true } else { false } } == true)
        #expect(hostSide.sent.last == .bye(reason: "timeout"))
    }

    @Test func failsWhenTheGuestGoesAway() async throws {
        let guest = try FakeGuest()
        let port = try await guest.start()
        let (hostSide, _) = LocalSignaling.pair()
        let peer = HostPeer(transport: hostSide, iceServers: [], sessionID: UUID()) {
            NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        }
        let run = Task { try await peer.run() }
        try await Task.sleep(for: .milliseconds(300))
        guest.listener.cancel()
        guest.send(.hello(guest.hello))
        await #expect(throws: HostPeerError.self) {
            // Closing the guest's socket ends the session with an error.
            try await Task.sleep(for: .milliseconds(50))
            guestConnectionClose(guest)
            _ = try await run.value
        }
    }

    @Test func iceServerURLsForLibDataChannel() {
        let urls = RTCPeerConnection.iceServerURLs([
            (["stun:turn.example.com:3478", "turn:turn.example.com:3478?transport=udp", "turns:turn.example.com:5349"], "1761000000:5D6C", "a/b+c="),
            (["turn:no-credentials.example.com"], nil, nil),
        ])
        #expect(urls == [
            "stun:turn.example.com:3478",
            "turn:1761000000%3A5D6C:a%2Fb%2Bc%3D@turn.example.com:3478?transport=udp",
            "turns:1761000000%3A5D6C:a%2Fb%2Bc%3D@turn.example.com:5349",
        ])
    }

    @Test func pickNegotiatedPayloadType() {
        let answer = "v=0\r\nm=video 9 UDP/TLS/RTP/SAVPF 97 96\r\na=mid:video\r\na=extmap:4 http://www.webrtc.org/experiments/rtp-hdrext/playout-delay\r\n"
        #expect(HostPeer.negotiatedPayloadType(answer) == 97)
        #expect(HostPeer.acceptsPlayoutDelay(answer))
        #expect(HostPeer.videoMediaDescription().hasPrefix("m=video 9 UDP/TLS/RTP/SAVPF 96 97 98\r\n"))
    }
}

private func guestConnectionClose(_ guest: FakeGuest) {
    guest.queue.sync { (Mirror(reflecting: guest).children.first { $0.label == "connection" }?.value as? NWConnection)?.cancel() }
}
