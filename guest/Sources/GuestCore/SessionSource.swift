import Foundation
import MaccheriProtocol

/// What the host asked for, read from the share.
public enum SessionSource {
    /// The pre-`session.json` hand-off of `AgentCore.JobRunner`: the bare JIT config in `jitconfig`.
    /// Accepted until the agent moves to ``GuestAPI/sessionFile``.
    public static let legacyJITConfigFile = "jitconfig"

    /// Reads the session if the host has written it. A half-written file fails to decode and is
    /// retried on the next poll.
    public static func read(share: URL) -> GuestSession? {
        if let data = try? Data(contentsOf: share.appending(path: GuestAPI.sessionFile)) {
            return try? JSONDecoder().decode(GuestSession.self, from: data)
        }
        if let data = try? Data(contentsOf: share.appending(path: legacyJITConfigFile)) {
            let config = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return config.isEmpty ? nil : .ci(GuestCIJob(jitConfig: config))
        }
        return nil
    }

    /// Polls the share until a session appears.
    public static func wait(share: URL, every interval: Duration = .milliseconds(500)) async throws -> GuestSession {
        while true {
            if let session = read(share: share) { return session }
            try await Task.sleep(for: interval)
        }
    }
}
