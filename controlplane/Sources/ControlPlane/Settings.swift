import Foundation
import MaccheriProtocol
import Vapor

/// Everything configurable comes from the environment; see `DESIGN.md` for the table.
struct Settings: Sendable {
    /// `https://maccheri.example.com`; signaling URLs are built from it.
    var publicURL: URL
    var databasePath: String
    /// `web/dist`; nil serves no web client.
    var publicDirectory: String?
    /// `MACCHERI_SHARED_TOKEN`: one bearer token for the whole team, accepted wherever a user token is.
    /// Requests with it act as the built-in admin user ``AuthController/teamUserID``. Invites stay optional.
    var sharedToken: String?
    /// Creates this invite for the first admin when there is none yet.
    var adminInvite: String?
    var inviteTTLSeconds: Int = 7 * 86_400

    var sessionSeconds: Int = 3600
    var maxSessionsPerUser: Int = 2
    var sessionQueueSeconds: Int = 120
    var sessionStartSeconds: Int = 300
    var warmPreferenceSeconds: Int = 5
    var longPollSeconds: Int = WorkAPI.longPollSeconds
    var offlineAfterSeconds: Int = HostAPI.offlineAfterSeconds
    /// How often expiry and offline hosts are checked; nil disables the background sweep (tests).
    var sweepSeconds: Int? = 5

    var turn: TURNSettings?
    /// STUN servers handed out when there is no TURN.
    var stunURLs: [String] = []

    /// `X-Hub-Signature-256` secret configured on the GitHub App; nil disables the webhook.
    var webhookSecret: String?
    /// Jobs are taken only when `runs-on` contains this label.
    var runnerLabel: String = "maccheri"
    var defaultImage: String = "macos-27-xcode-27.2"
    var jobTimeoutSeconds: Int = 3600
    var github: GitHubAppCredentials?

    static func fromEnvironment() throws -> Settings {
        func string(_ key: String) -> String? {
            guard let value = Environment.get(key), !value.isEmpty else { return nil }
            return value
        }
        func int(_ key: String) throws -> Int? {
            guard let value = string(key) else { return nil }
            guard let number = Int(value) else { throw Abort(.internalServerError, reason: "\(key) is not a number") }
            return number
        }
        func list(_ key: String) -> [String] {
            string(key)?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
        }

        guard let publicURL = URL(string: string("PUBLIC_URL") ?? "http://localhost:8080") else {
            throw Abort(.internalServerError, reason: "PUBLIC_URL is not a URL")
        }
        var settings = Settings(
            publicURL: publicURL,
            databasePath: string("DATABASE_PATH") ?? "maccheri.sqlite",
            publicDirectory: string("PUBLIC_DIR"),
            adminInvite: string("ADMIN_INVITE")
        )
        settings.sharedToken = string("MACCHERI_SHARED_TOKEN")
        if let hours = try int("INVITE_TTL_HOURS") { settings.inviteTTLSeconds = hours * 3600 }
        if let minutes = try int("SESSION_MINUTES") { settings.sessionSeconds = minutes * 60 }
        if let value = try int("MAX_SESSIONS_PER_USER") { settings.maxSessionsPerUser = value }
        if let value = try int("SESSION_QUEUE_SECONDS") { settings.sessionQueueSeconds = value }
        if let value = try int("SESSION_START_SECONDS") { settings.sessionStartSeconds = value }
        if let value = try int("WARM_PREFERENCE_SECONDS") { settings.warmPreferenceSeconds = value }

        if let host = string("TURN_HOST"), let secret = string("TURN_SECRET") {
            settings.turn = TURNSettings(
                host: host,
                secret: secret,
                port: try int("TURN_PORT") ?? 3478,
                tlsPort: try int("TURN_TLS_PORT") ?? 443
            )
        }
        settings.stunURLs = list("STUN_URLS")

        settings.webhookSecret = string("GITHUB_WEBHOOK_SECRET")
        if let label = string("RUNNER_LABEL") { settings.runnerLabel = label }
        if let image = string("DEFAULT_IMAGE") { settings.defaultImage = image }
        if let value = try int("JOB_TIMEOUT_SECONDS") { settings.jobTimeoutSeconds = value }

        var privateKey = string("GITHUB_APP_PRIVATE_KEY")?.replacingOccurrences(of: "\\n", with: "\n")
        if privateKey == nil, let file = string("GITHUB_APP_PRIVATE_KEY_FILE") {
            privateKey = try String(contentsOfFile: file, encoding: .utf8)
        }
        if let appID = string("GITHUB_APP_ID"), let privateKey {
            settings.github = GitHubAppCredentials(appID: appID, privateKeyPEM: privateKey)
        }
        return settings
    }
}

struct TURNSettings: Sendable {
    var host: String
    /// coturn `static-auth-secret`.
    var secret: String
    var port: Int
    var tlsPort: Int
}
