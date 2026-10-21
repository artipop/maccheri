import Crypto
import Foundation

/// Bearer tokens and codes: `<prefix>_<32 random bytes, base64url>`. Only their SHA-256 is stored,
/// except signaling tokens (see `DESIGN.md`).
enum Tokens {
    static let invite = "mci"
    static let user = "mcu"
    static let agent = "mca"
    static let signaling = "mcs"

    static func make(_ prefix: String, bytes: Int = 32) -> String {
        var generator = SystemRandomNumberGenerator()
        let random = (0..<bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return "\(prefix)_\(GitHubAppJWT.base64URL(Data(random)))"
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Compares without leaking where the first difference is.
    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let a = Array(a.utf8), b = Array(b.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
