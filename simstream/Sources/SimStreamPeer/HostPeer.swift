import Foundation
import LibDataChannel
import MaccheriProtocol
import Network
import SimStreamProtocol

/// The Mac side of a remote simulator session: joins the session's signaling channel as the host,
/// offers WebRTC to the viewer and relays SimStream between the viewer and the guest's `simstream`.
///
/// What the offer contains:
/// - `control` data channel (reliable, ordered): every SimStream message except video, as
///   ``SimStreamMessage/encodedBody()``;
/// - `video` data channel (ordered, retransmits for up to ``Options/videoLifetimeMs``): video as
///   ``VideoChunk``s, when the viewer asks for ``StreamConfig/VideoTransport/dataChannel``;
/// - an H.264 video track (RTP, NACK, PLI, playout delay 0) with ``FrameInfo`` on `control`, when
///   the viewer asks for ``StreamConfig/VideoTransport/track``.
///
/// No video flows until the viewer sends ``StreamConfig``. Video passes through as the guest
/// encoded it: there is no transcoding and no congestion control on this side (see README).
public final class HostPeer: @unchecked Sendable {
    public struct Options: Sendable {
        /// How long the viewer has to connect.
        public var connectTimeout: TimeInterval = 120
        /// How long a dropped connection may stay down before the session ends.
        public var disconnectGrace: TimeInterval = 10
        /// Force TURN (testing).
        public var relayOnly = false
        /// Data channel mode: payload bytes per chunk. 16 KiB messages pass in every browser.
        public var videoChunkSize = 16 * 1024 - 16
        /// Data channel mode: frames are dropped while more than this waits to be sent.
        public var maxVideoBuffered = 1 << 20
        /// Data channel mode: how long SCTP keeps retransmitting a video chunk.
        public var videoLifetimeMs: UInt32 = 200

        public init() {}
    }

    public enum EndReason: Sendable, Equatable {
        case bye(String?)
        case disconnected
        case connectTimeout
        case stopped(String?)
    }

    private let transport: SignalingTransport
    private let iceServers: [ICEServer]
    private let sessionID: UUID
    private let options: Options
    private let connectToGuest: @Sendable () async throws -> NWConnection
    private let queue = DispatchQueue(label: "host-peer", qos: .userInteractive)

    /// Log lines; prints when nil.
    public var onLog: (@Sendable (String) -> Void)?

    // Queue state.
    private var pc: RTCPeerConnection?
    private var control: RTCChannel?
    private var video: RTCChannel?
    private var track: RTCChannel?
    private var trackReady = false
    private var guest: NWConnection?
    private var guestReader = MessageReader()
    private var hello: Hello?
    private var transportMode: StreamConfig.VideoTransport?
    private var waitingForKeyframe = true
    private var lastKeyframeRequest: UInt64 = 0
    private var videoFrame: UInt32 = 0
    private var connected = false
    private var everConnected = false
    private var disconnectTimer: DispatchWorkItem?
    private var finished = false
    private var continuation: CheckedContinuation<EndReason, Error>?
    private var stats = (frames: 0, bytes: 0, dropped: 0)
    private var statsTimer: DispatchSourceTimer?

    private static let videoSSRC: UInt32 = 0x5157_0001
    private static let playoutDelayExtension: UInt8 = 4

    /// Per the A ↔ D contract: the agent calls ``run()`` once the guest is ready.
    /// `connectToGuest` returns a connection to the guest's `simstream`, started or not.
    public convenience init(signaling: SignalingInfo, sessionID: UUID, connectToGuest: @escaping @Sendable () async throws -> NWConnection) {
        self.init(transport: WebSocketSignaling(url: signaling.url), iceServers: signaling.iceServers, sessionID: sessionID, connectToGuest: connectToGuest)
    }

    public init(transport: SignalingTransport, iceServers: [ICEServer], sessionID: UUID, options: Options = Options(), connectToGuest: @escaping @Sendable () async throws -> NWConnection) {
        self.transport = transport
        self.iceServers = iceServers
        self.sessionID = sessionID
        self.options = options
        self.connectToGuest = connectToGuest
    }

    /// Returns when the viewer leaves (bye / disconnect / timeout) or ``stop(reason:)`` is called;
    /// throws if the guest or the signaling channel fails first. Cancelling the task stops the peer.
    @discardableResult
    public func run() async throws -> EndReason {
        let guest = try await connectToGuest()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    self.continuation = continuation
                    do {
                        try self.start(guest: guest)
                    } catch {
                        self.finish(.failure(error))
                    }
                }
                Task { await self.signalingLoop() }
            }
        } onCancel: {
            self.stop(reason: "cancelled")
        }
    }

    /// Ends the session from the host's side: sends `bye` and makes ``run()`` return.
    public func stop(reason: String?) {
        queue.async {
            guard !self.finished else { return }
            self.signal(.bye(reason: reason))
            self.finish(.success(.stopped(reason)))
        }
    }

    // MARK: - Setup

    private func start(guest: NWConnection) throws {
        startGuest(guest)

        let servers = RTCPeerConnection.iceServerURLs(iceServers.map { ($0.urls, $0.username, $0.credential) })
        let pc = try RTCPeerConnection(.init(iceServers: servers, relayOnly: options.relayOnly))
        self.pc = pc
        pc.onLocalDescription = { [weak self] sdp, type in
            self?.signal(type == "offer" ? .offer(sdp: sdp) : .answer(sdp: sdp))
        }
        pc.onLocalCandidate = { [weak self] candidate, mid in
            self?.signal(.candidate(candidate: candidate, sdpMid: mid, sdpMLineIndex: nil))
        }
        pc.onState = { [weak self] state in
            self?.queue.async { self?.connectionState(state) }
        }

        let control = try pc.createDataChannel("control")
        control.onOpen = { [weak self] in
            self?.queue.async {
                guard let self, let hello = self.hello else { return }
                self.sendControl(.hello(hello))
            }
        }
        control.onMessage = { [weak self] data in self?.queue.async { self?.fromViewer(data) } }
        self.control = control

        let video = try pc.createDataChannel("video", maxPacketLifeTimeMs: options.videoLifetimeMs)
        self.video = video

        let track = try pc.addTrack(mediaDescription: Self.videoMediaDescription())
        track.onOpen = { [weak self] in self?.queue.async { self?.trackOpened() } }
        track.onKeyframeRequest = { [weak self] in self?.queue.async { self?.requestKeyframe() } }
        self.track = track

        try pc.setLocalDescription("offer")

        queue.asyncAfter(deadline: .now() + options.connectTimeout) { [weak self] in
            guard let self, !self.everConnected else { return }
            self.log("viewer did not connect in \(Int(self.options.connectTimeout)) s")
            self.signal(.bye(reason: "timeout"))
            self.finish(.success(.connectTimeout))
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.logStats() }
        timer.resume()
        statsTimer = timer
    }

    /// H.264 offered under the profiles browsers answer to; the stream is whatever VideoToolbox
    /// produced (High), which every browser's decoder takes regardless of the negotiated profile.
    static func videoMediaDescription() -> String {
        let profiles = [(96, "42e01f"), (97, "640c1f"), (98, "64001f")]
        var lines = ["m=video 9 UDP/TLS/RTP/SAVPF \(profiles.map { String($0.0) }.joined(separator: " "))", "c=IN IP4 0.0.0.0", "a=mid:video", "a=sendonly"]
        for (pt, profile) in profiles {
            lines += [
                "a=rtpmap:\(pt) H264/90000",
                "a=fmtp:\(pt) level-asymmetry-allowed=1;packetization-mode=1;profile-level-id=\(profile)",
                "a=rtcp-fb:\(pt) nack",
                "a=rtcp-fb:\(pt) nack pli",
            ]
        }
        lines += [
            "a=extmap:\(playoutDelayExtension) http://www.webrtc.org/experiments/rtp-hdrext/playout-delay",
            "a=ssrc:\(videoSSRC) cname:simstream",
            "a=ssrc:\(videoSSRC) msid:simstream video",
        ]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    /// The H.264 payload type the answer kept, first in the track's `m=` line.
    static func negotiatedPayloadType(_ description: String) -> UInt8? {
        guard let line = description.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("m=video") }) else { return nil }
        return line.split(separator: " ").dropFirst(3).first.flatMap { UInt8($0) }
    }

    /// Whether the answer accepted the playout-delay header extension.
    static func acceptsPlayoutDelay(_ description: String) -> Bool {
        description.contains("rtp-hdrext/playout-delay")
    }

    private func trackOpened() {
        guard let track else { return }
        let description = track.trackDescription ?? ""
        let pt = Self.negotiatedPayloadType(description) ?? 96
        do {
            try track.setUpH264Sender(ssrc: Self.videoSSRC, payloadType: pt,
                                      playoutDelayExtensionID: Self.acceptsPlayoutDelay(description) ? Self.playoutDelayExtension : nil)
            trackReady = true
            log("video track open, H.264 payload type \(pt)")
            if transportMode == .track { requestKeyframe() }
        } catch {
            log("video track: \(error)")
        }
    }

    // MARK: - Signaling

    private func signal(_ message: SignalMessage) {
        let transport = transport
        Task { [weak self] in
            do {
                try await transport.send(message)
            } catch {
                self?.log("signaling send: \(error)")
            }
        }
    }

    private func signalingLoop() async {
        do {
            while let message = try await transport.receive() {
                queue.async { self.handle(message) }
                if case .bye = message { return }
            }
            queue.async {
                // The control plane went away. A connected session carries on without it.
                guard !self.everConnected else { return self.log("signaling closed") }
                self.finish(.failure(HostPeerError.signalingClosed))
            }
        } catch {
            queue.async {
                guard !self.everConnected else { return self.log("signaling: \(error)") }
                self.finish(.failure(error))
            }
        }
    }

    private func handle(_ message: SignalMessage) {
        guard !finished, let pc else { return }
        do {
            switch message {
            case .answer(let sdp):
                try pc.setRemoteDescription(sdp: sdp, type: "answer")
            case .offer:
                log("ignoring an offer: the host offers")
            case .candidate(let candidate, let mid, _):
                // Browsers end gathering with an empty candidate.
                guard !candidate.isEmpty else { return }
                try pc.addRemoteCandidate(candidate, mid: mid)
            case .bye(let reason):
                log("viewer said bye\(reason.map { ": \($0)" } ?? "")")
                finish(.success(.bye(reason)))
            }
        } catch {
            log("signaling \(message): \(error)")
        }
    }

    private func connectionState(_ state: rtcState) {
        guard !finished else { return }
        switch state {
        case RTC_CONNECTED:
            connected = true
            everConnected = true
            disconnectTimer?.cancel()
            disconnectTimer = nil
            log("connected: \(connectionDescription())")
        case RTC_DISCONNECTED, RTC_FAILED, RTC_CLOSED:
            connected = false
            guard disconnectTimer == nil else { return }
            let grace = state == RTC_DISCONNECTED ? options.disconnectGrace : 0
            log("connection \(state == RTC_DISCONNECTED ? "lost" : "closed"), ending in \(Int(grace)) s unless it recovers")
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.connected else { return }
                self.signal(.bye(reason: "disconnected"))
                self.finish(.success(.disconnected))
            }
            disconnectTimer = item
            queue.asyncAfter(deadline: .now() + grace, execute: item)
        default:
            break
        }
    }

    /// e.g. "direct (host 192.168.1.5 ⇄ srflx 203.0.113.7)" or "relay (…)".
    private func connectionDescription() -> String {
        guard let pair = pc?.selectedCandidatePair else { return "?" }
        func kind(_ candidate: String) -> String {
            let parts = candidate.split(separator: " ")
            let type = parts.firstIndex(of: "typ").flatMap { $0 + 1 < parts.count ? String(parts[$0 + 1]) : nil } ?? "?"
            let address = parts.count > 5 ? "\(parts[4]):\(parts[5])" : candidate
            return "\(type) \(address)"
        }
        let relayed = pair.local.contains("typ relay") || pair.remote.contains("typ relay")
        return "\(relayed ? "relay" : "direct") (\(kind(pair.local)) ⇄ \(kind(pair.remote)))"
    }

    // MARK: - Guest

    private func startGuest(_ connection: NWConnection) {
        guest = connection
        let previous = connection.stateUpdateHandler
        connection.stateUpdateHandler = { [weak self] state in
            previous?(state)
            switch state {
            case .failed(let error):
                self?.queue.async { self?.finish(.failure(HostPeerError.guest("\(error)"))) }
            case .cancelled:
                self?.queue.async { self?.finish(.failure(HostPeerError.guest("connection closed"))) }
            default:
                break
            }
        }
        if case .setup = connection.state { connection.start(queue: queue) }
        receiveFromGuest(connection)
    }

    private func receiveFromGuest(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 << 10) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                guard !self.finished else { return }
                if let data {
                    do {
                        for message in try self.guestReader.append(data) { self.fromGuest(message) }
                    } catch {
                        return self.finish(.failure(HostPeerError.guest("bad message: \(error)")))
                    }
                }
                if isComplete || error != nil {
                    return self.finish(.failure(HostPeerError.guest(error.map { "\($0)" } ?? "closed by the guest")))
                }
                self.receiveFromGuest(connection)
            }
        }
    }

    private func toGuest(_ message: SimStreamMessage) {
        guest?.send(content: message.encoded(), completion: .idempotent)
    }

    private func fromGuest(_ message: SimStreamMessage) {
        switch message {
        case .hello(let h):
            hello = h
            sendControl(message)
        case .video(let frame):
            sendVideo(frame)
        case .pong, .installStatus:
            sendControl(message)
        default:
            break
        }
    }

    // MARK: - Viewer

    private func sendControl(_ message: SimStreamMessage) {
        guard let control, control.isOpen else { return }
        control.send(message.encodedBody())
    }

    private func fromViewer(_ data: Data) {
        let message: SimStreamMessage
        do {
            message = try SimStreamMessage(body: data)
        } catch {
            return log("bad message from the viewer: \(error)")
        }
        switch message {
        case .streamConfig(let config):
            log("viewer wants video over \(config.video == .track ? "the RTP track" : "the data channel")")
            transportMode = config.video
            waitingForKeyframe = true
            requestKeyframe(force: true)
        case .requestKeyframe:
            waitingForKeyframe = true
            requestKeyframe(force: true)
        case .touch, .key, .button, .orientation, .installBegin, .installChunk, .installEnd, .ping, .pong:
            toGuest(message)
        case .hello, .video, .installStatus, .frameInfo, .videoChunk:
            break
        }
    }

    /// PLIs come in bursts; one keyframe per 100 ms is plenty.
    private func requestKeyframe(force: Bool = false) {
        let now = DispatchTime.now().uptimeNanoseconds / 1_000_000
        guard force || now - lastKeyframeRequest >= 100 else { return }
        lastKeyframeRequest = now
        toGuest(.requestKeyframe)
    }

    private func sendVideo(_ frame: VideoFrame) {
        guard connected, let mode = transportMode else { return }
        if waitingForKeyframe, !frame.isKeyframe { return }
        switch mode {
        case .track:
            guard trackReady, let track, let control else { return }
            var unit = Data()
            if frame.isKeyframe {
                for set in frame.parameterSets {
                    withUnsafeBytes(of: UInt32(set.count).bigEndian) { unit.append(contentsOf: $0) }
                    unit.append(set)
                }
            }
            unit.append(frame.payload)
            let timestamp = Self.rtpTimestamp(captureMicros: frame.captureMicros)
            // Metadata first, so it is there when the frame is presented.
            control.send(SimStreamMessage.frameInfo(FrameInfo(
                rtpTimestamp: timestamp, isKeyframe: frame.isKeyframe, inputAck: frame.inputAck,
                ackAgeMicros: frame.ackAgeMicros, encodeMicros: frame.encodeMicros
            )).encodedBody())
            track.setRTPTimestamp(timestamp)
            track.send(unit)
            account(frame, bytes: unit.count)
        case .dataChannel:
            guard let video, video.isOpen else { return }
            if video.bufferedAmount > options.maxVideoBuffered {
                // The path can't keep up: skip frames until a keyframe restarts the picture.
                stats.dropped += 1
                waitingForKeyframe = true
                requestKeyframe()
                return
            }
            let body = SimStreamMessage.video(frame).encodedBody()
            videoFrame &+= 1
            for chunk in VideoChunk.slice(body, frame: videoFrame, size: options.videoChunkSize) {
                video.send(SimStreamMessage.videoChunk(chunk).encodedBody())
            }
            account(frame, bytes: body.count)
        }
    }

    private func account(_ frame: VideoFrame, bytes: Int) {
        if frame.isKeyframe { waitingForKeyframe = false }
        stats.frames += 1
        stats.bytes += bytes
    }

    /// 90 kHz clock from the guest's capture time.
    static func rtpTimestamp(captureMicros: UInt64) -> UInt32 {
        UInt32(truncatingIfNeeded: captureMicros * 9 / 100)
    }

    // MARK: - End

    private func finish(_ result: Result<EndReason, Error>) {
        guard !finished else { return }
        finished = true
        switch result {
        case .success(let reason): log("session \(sessionID) ended: \(reason)")
        case .failure(let error): log("session \(sessionID) failed: \(error)")
        }
        statsTimer?.cancel()
        disconnectTimer?.cancel()
        control?.close()
        video?.close()
        track?.close()
        pc?.close()
        control = nil
        video = nil
        track = nil
        pc = nil
        guest?.stateUpdateHandler = nil
        guest?.cancel()
        guest = nil
        // Let a pending bye leave before the socket goes.
        let transport = transport
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { transport.close() }
        continuation?.resume(with: result)
        continuation = nil
    }

    private func logStats() {
        guard connected else { return }
        log(String(format: "5 s: %d frames, %.2f Mbit/s, %d dropped, %@", stats.frames, Double(stats.bytes * 8) / 5e6, stats.dropped,
                   transportMode.map { $0 == .track ? "track" : "data channel" } ?? "no video yet"))
        stats = (0, 0, 0)
    }

    private func log(_ line: String) {
        if let onLog { onLog(line) } else { print("host-peer: \(line)") }
    }
}

public enum HostPeerError: Error, CustomStringConvertible {
    case guest(String)
    case signalingClosed

    public var description: String {
        switch self {
        case .guest(let s): "guest: \(s)"
        case .signalingClosed: "signaling closed before the viewer connected"
        }
    }
}
