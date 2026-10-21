import Crypto
import Foundation
import MaccheriProtocol

/// ICE servers for one session. TURN credentials follow the TURN REST API that coturn's
/// `use-auth-secret` checks: `username = "<expiry>:<session id>"`, `credential = base64(HMAC-SHA1(secret, username))`.
enum ICEServers {
    static func make(for sessionID: UUID, expiresAt: Date, settings: Settings) -> [ICEServer] {
        guard let turn = settings.turn else {
            return settings.stunURLs.isEmpty ? [] : [ICEServer(urls: settings.stunURLs)]
        }
        let username = "\(Int(expiresAt.timeIntervalSince1970)):\(sessionID.uuidString)"
        return [
            ICEServer(urls: ["stun:\(turn.host):\(turn.port)"]),
            ICEServer(
                urls: [
                    "turn:\(turn.host):\(turn.port)?transport=udp",
                    "turn:\(turn.host):\(turn.port)?transport=tcp",
                    "turns:\(turn.host):\(turn.tlsPort)?transport=tcp",
                ],
                username: username,
                credential: credential(username: username, secret: turn.secret)
            ),
        ]
    }

    static func credential(username: String, secret: String) -> String {
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(username.utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return Data(mac).base64EncodedString()
    }
}

extension SessionModel {
    func signalingInfo(for role: SignalingRole, settings: Settings) -> SignalingInfo {
        var components = URLComponents(url: settings.publicURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.path = (components.path.hasSuffix("/") ? String(components.path.dropLast()) : components.path)
            + SignalingAPI.signalPath(sessionID: id!)
        components.queryItems = [URLQueryItem(name: "role", value: role.rawValue), URLQueryItem(name: "token", value: token(for: role))]
        return SignalingInfo(
            url: components.url!,
            token: token(for: role),
            iceServers: ICEServers.make(for: id!, expiresAt: expiresAt, settings: settings)
        )
    }
}
