import Foundation

/// Peer-to-peer setup between the viewer and the host (WebRTC). The control plane only relays
/// these small messages; media and input go directly between the peers, or through TURN when
/// no direct path exists.
///
///     GET /v1/sessions/{id}/signal?role=viewer|host&token=<SignalingInfo.token>   WebSocket
///
/// The token travels in the query because browsers can't set headers on a WebSocket; it is
/// per-session and per-role, so it is fine in a URL, but servers must not log it.
/// ``SignalingInfo/url`` already contains `role` and `token`: clients open it as is.
///
/// Each WebSocket text frame is one JSON ``SignalMessage``. The control plane forwards every frame
/// from one role to the other, unchanged, and queues frames sent before the other side joined.
/// The host side creates the offer.
public enum SignalingAPI {
    public static func signalPath(sessionID: UUID) -> String { "/v1/sessions/\(sessionID.uuidString)/signal" }
}

public enum SignalingRole: String, Codable, Sendable {
    case viewer
    case host
}

public struct ICEServer: Codable, Sendable, Equatable {
    /// e.g. `["stun:turn.example.com:3478", "turn:turn.example.com:3478?transport=udp"]`.
    public var urls: [String]
    /// Short-lived TURN credentials (TURN REST API: `username = "<expiry>:<session id>"`).
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

/// Everything one side needs to join a session's signaling channel.
public struct SignalingInfo: Codable, Sendable, Equatable {
    /// Absolute `wss://` URL of the session's signaling endpoint, with `role` and `token` in the query.
    public var url: URL
    /// The same per-session, per-role token as in ``url``; it is not the user's or the agent's
    /// long-lived token.
    public var token: String
    public var iceServers: [ICEServer]

    public init(url: URL, token: String, iceServers: [ICEServer]) {
        self.url = url
        self.token = token
        self.iceServers = iceServers
    }
}

public enum SignalMessage: Codable, Sendable, Equatable {
    case offer(sdp: String)
    case answer(sdp: String)
    case candidate(candidate: String, sdpMid: String?, sdpMLineIndex: Int32?)
    /// Either side is leaving; the other should tear down.
    case bye(reason: String?)
}
