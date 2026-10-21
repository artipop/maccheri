import Foundation
import LibDataChannel

// A thin Swift layer over libdatachannel's C API. Callbacks arrive on libdatachannel's own threads;
// owners hop to their queue. Callbacks find their object through the user pointer, which holds a
// reference until `close()`: every object must be closed, or it leaks along with its native side.

public struct RTCError: Error, CustomStringConvertible {
    public let call: String
    public let code: Int32
    public var description: String { "\(call) failed (\(code))" }

    @discardableResult
    static func check(_ code: Int32, _ call: String) throws -> Int32 {
        guard code >= 0 else { throw RTCError(call: call, code: code) }
        return code
    }
}

enum RTCLog {
    /// `SIMSTREAM_RTC_LOG=debug|info|warning` sends libdatachannel's log to stdout.
    static let setUp: Void = {
        let level: rtcLogLevel = switch ProcessInfo.processInfo.environment["SIMSTREAM_RTC_LOG"] {
        case "verbose": RTC_LOG_VERBOSE
        case "debug": RTC_LOG_DEBUG
        case "info": RTC_LOG_INFO
        case "warning": RTC_LOG_WARNING
        default: RTC_LOG_ERROR
        }
        rtcInitLogger(level, { _, message in
            if let message { print("rtc: \(String(cString: message))") }
        })
    }()
}

public final class RTCPeerConnection: @unchecked Sendable {
    public struct Configuration {
        /// libdatachannel form: `stun:host:port`, `turn:user:pass@host:port?transport=udp`, with
        /// user and password percent-encoded (see ``iceServerURLs(_:)``).
        public var iceServers: [String] = []
        public var relayOnly = false

        public init(iceServers: [String] = [], relayOnly: Bool = false) {
            self.iceServers = iceServers
            self.relayOnly = relayOnly
        }
    }

    public let id: Int32
    // Set before the first description is created.
    public var onLocalDescription: (@Sendable (_ sdp: String, _ type: String) -> Void)?
    public var onLocalCandidate: (@Sendable (_ candidate: String, _ mid: String?) -> Void)?
    public var onState: (@Sendable (rtcState) -> Void)?
    /// Channels the other side opened.
    public var onDataChannel: (@Sendable (RTCChannel, _ label: String) -> Void)?

    public init(_ configuration: Configuration) throws {
        _ = RTCLog.setUp
        var cStrings = configuration.iceServers.map { strdup($0) }
        defer { cStrings.forEach { free($0) } }
        var config = rtcConfiguration()
        config.iceTransportPolicy = configuration.relayOnly ? RTC_TRANSPORT_POLICY_RELAY : RTC_TRANSPORT_POLICY_ALL
        config.disableAutoNegotiation = true
        id = try cStrings.withUnsafeMutableBufferPointer { buffer in
            try buffer.withMemoryRebound(to: UnsafePointer<CChar>?.self) { servers in
                config.iceServers = servers.baseAddress
                config.iceServersCount = Int32(servers.count)
                return try RTCError.check(rtcCreatePeerConnection(&config), "rtcCreatePeerConnection")
            }
        }
        rtcSetUserPointer(id, Unmanaged.passRetained(self).toOpaque())
        rtcSetLocalDescriptionCallback(id) { _, sdp, type, ptr in
            guard let sdp, let type else { return }
            RTCPeerConnection.from(ptr)?.onLocalDescription?(String(cString: sdp), String(cString: type))
        }
        rtcSetLocalCandidateCallback(id) { _, candidate, mid, ptr in
            guard let candidate else { return }
            RTCPeerConnection.from(ptr)?.onLocalCandidate?(String(cString: candidate), mid.map { String(cString: $0) })
        }
        rtcSetStateChangeCallback(id) { _, state, ptr in
            RTCPeerConnection.from(ptr)?.onState?(state)
        }
        rtcSetDataChannelCallback(id) { pc, dc, _ in
            // The new channel's user pointer is unset here; the connection's comes from the pc id.
            guard let connection = RTCPeerConnection.from(rtcGetUserPointer(pc)) else { return }
            var label = [CChar](repeating: 0, count: 256)
            rtcGetDataChannelLabel(dc, &label, 256)
            connection.onDataChannel?(RTCChannel(id: dc), String(cString: label))
        }
    }

    private static func from(_ ptr: UnsafeMutableRawPointer?) -> RTCPeerConnection? {
        ptr.map { Unmanaged<RTCPeerConnection>.fromOpaque($0).takeUnretainedValue() }
    }

    /// Creates the offer (or, after a remote offer, the answer); it arrives in ``onLocalDescription``.
    public func setLocalDescription(_ type: String? = nil) throws {
        try RTCError.check(rtcSetLocalDescription(id, type), "rtcSetLocalDescription")
    }

    public func setRemoteDescription(sdp: String, type: String) throws {
        try RTCError.check(rtcSetRemoteDescription(id, sdp, type), "rtcSetRemoteDescription")
    }

    public func addRemoteCandidate(_ candidate: String, mid: String?) throws {
        try RTCError.check(rtcAddRemoteCandidate(id, candidate, mid), "rtcAddRemoteCandidate")
    }

    public func createDataChannel(_ label: String, unordered: Bool = false, maxPacketLifeTimeMs: UInt32? = nil, maxRetransmits: UInt32? = nil) throws -> RTCChannel {
        var initialization = rtcDataChannelInit()
        initialization.reliability.unordered = unordered
        if let maxPacketLifeTimeMs {
            initialization.reliability.unreliable = true
            initialization.reliability.maxPacketLifeTime = maxPacketLifeTimeMs
        } else if let maxRetransmits {
            initialization.reliability.unreliable = true
            initialization.reliability.maxRetransmits = maxRetransmits
        }
        return RTCChannel(id: try RTCError.check(rtcCreateDataChannelEx(id, label, &initialization), "rtcCreateDataChannelEx"))
    }

    /// Adds a media track from its SDP media description (`m=` line and attributes).
    public func addTrack(mediaDescription: String) throws -> RTCChannel {
        RTCChannel(id: try RTCError.check(rtcAddTrack(id, mediaDescription), "rtcAddTrack"))
    }

    /// `(local, remote)` candidates of the selected pair, once connected.
    public var selectedCandidatePair: (local: String, remote: String)? {
        var local = [CChar](repeating: 0, count: 512), remote = [CChar](repeating: 0, count: 512)
        guard rtcGetSelectedCandidatePair(id, &local, 512, &remote, 512) >= 0 else { return nil }
        return (String(cString: local), String(cString: remote))
    }

    public var remoteDescription: String? {
        var buffer = [CChar](repeating: 0, count: 64 << 10)
        guard rtcGetRemoteDescription(id, &buffer, Int32(buffer.count)) >= 0 else { return nil }
        return String(cString: buffer)
    }

    private let closed = NSLock()
    private var isClosed = false

    /// Unhooks the callbacks, closes and drops the callbacks' reference; safe to call more than once.
    public func close() {
        guard closed.withLock({ defer { isClosed = true }; return !isClosed }) else { return }
        rtcSetLocalDescriptionCallback(id, nil)
        rtcSetLocalCandidateCallback(id, nil)
        rtcSetStateChangeCallback(id, nil)
        rtcSetDataChannelCallback(id, nil)
        rtcClosePeerConnection(id)
        rtcDeletePeerConnection(id)
        Unmanaged.passUnretained(self).release()
    }

    /// `ICEServer`s from the control plane in libdatachannel's URL form. TURN usernames from the
    /// TURN REST API contain `:`, so credentials are percent-encoded.
    public static func iceServerURLs(_ servers: [(urls: [String], username: String?, credential: String?)]) -> [String] {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        return servers.flatMap { server in
            server.urls.compactMap { url -> String? in
                guard let colon = url.firstIndex(of: ":") else { return nil }
                let scheme = url[..<colon].lowercased()
                switch scheme {
                case "stun", "stuns":
                    return url
                case "turn", "turns":
                    guard let user = server.username, let password = server.credential else { return nil }
                    return "\(scheme):\(encode(user)):\(encode(password))@\(url[url.index(after: colon)...])"
                default:
                    return nil
                }
            }
        }
    }
}

/// A data channel or a media track: both send and receive messages.
public final class RTCChannel: @unchecked Sendable {
    public let id: Int32
    public var onOpen: (@Sendable () -> Void)?
    public var onClosed: (@Sendable () -> Void)?
    /// Binary messages; text messages arrive UTF-8 encoded.
    public var onMessage: (@Sendable (Data) -> Void)?
    /// Track only: the receiver asked for a keyframe (RTCP PLI).
    public var onKeyframeRequest: (@Sendable () -> Void)?

    init(id: Int32) {
        self.id = id
        rtcSetUserPointer(id, Unmanaged.passRetained(self).toOpaque())
        rtcSetOpenCallback(id) { _, ptr in RTCChannel.from(ptr)?.onOpen?() }
        rtcSetClosedCallback(id) { _, ptr in RTCChannel.from(ptr)?.onClosed?() }
        rtcSetMessageCallback(id) { _, message, size, ptr in
            guard let message, let channel = RTCChannel.from(ptr) else { return }
            let data = size >= 0 ? Data(bytes: message, count: Int(size)) : Data(String(cString: message).utf8)
            channel.onMessage?(data)
        }
    }

    private static func from(_ ptr: UnsafeMutableRawPointer?) -> RTCChannel? {
        ptr.map { Unmanaged<RTCChannel>.fromOpaque($0).takeUnretainedValue() }
    }

    public var isOpen: Bool { rtcIsOpen(id) }

    @discardableResult
    public func send(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            rtcSendMessage(id, raw.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(raw.count)) >= 0
        }
    }

    /// Bytes queued and not yet handed to the network.
    public var bufferedAmount: Int { Int(max(0, rtcGetBufferedAmount(id))) }

    /// Track only: SDP of the track after negotiation.
    public var trackDescription: String? {
        var buffer = [CChar](repeating: 0, count: 16 << 10)
        guard rtcGetTrackDescription(id, &buffer, Int32(buffer.count)) >= 0 else { return nil }
        return String(cString: buffer)
    }

    /// Track only: H.264 RTP packetization of length-prefixed (AVCC) access units, NACK
    /// retransmission from a history of `nackHistory` packets, sender reports and PLI.
    public func setUpH264Sender(ssrc: UInt32, payloadType: UInt8, playoutDelayExtensionID: UInt8?, nackHistory: UInt32 = 1024) throws {
        var config = rtcPacketizerInit()
        let cname = strdup("simstream")
        defer { free(cname) }
        config.ssrc = ssrc
        config.cname = UnsafePointer(cname)
        config.payloadType = payloadType
        config.clockRate = 90_000
        config.nalSeparator = RTC_NAL_SEPARATOR_LENGTH
        if let playoutDelayExtensionID {
            // min = max = 0: render on arrival, no jitter buffer target.
            config.playoutDelayId = playoutDelayExtensionID
            config.playoutDelayMin = 0
            config.playoutDelayMax = 0
        }
        try RTCError.check(rtcSetH264Packetizer(id, &config), "rtcSetH264Packetizer")
        try RTCError.check(rtcChainRtcpSrReporter(id), "rtcChainRtcpSrReporter")
        try RTCError.check(rtcChainRtcpNackResponder(id, nackHistory), "rtcChainRtcpNackResponder")
        try RTCError.check(rtcChainPliHandler(id) { _, ptr in RTCChannel.from(ptr)?.onKeyframeRequest?() }, "rtcChainPliHandler")
    }

    /// Track only: the RTP timestamp for the next `send`.
    public func setRTPTimestamp(_ timestamp: UInt32) {
        rtcSetTrackRtpTimestamp(id, timestamp)
    }

    private let closed = NSLock()
    private var isClosed = false

    /// Unhooks the callbacks, closes and drops the callbacks' reference; safe to call more than once.
    public func close() {
        guard closed.withLock({ defer { isClosed = true }; return !isClosed }) else { return }
        rtcSetOpenCallback(id, nil)
        rtcSetClosedCallback(id, nil)
        rtcSetMessageCallback(id, nil)
        rtcClose(id)
        rtcDelete(id)
        Unmanaged.passUnretained(self).release()
    }
}
