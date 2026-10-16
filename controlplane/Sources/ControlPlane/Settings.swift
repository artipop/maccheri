import Vapor

struct Settings: Sendable {
    /// `X-Hub-Signature-256` secret configured on the GitHub App.
    var webhookSecret: String
    /// Bearer tokens accepted from host agents. Per-host credentials come later.
    var agentTokens: Set<String>
    /// Jobs are taken only when `runs-on` contains this label.
    var runnerLabel: String
    var defaultImage: String
    var jobTimeoutSeconds: Int
    var github: GitHubAppCredentials?

    static func fromEnvironment() throws -> Settings {
        func require(_ key: String) throws -> String {
            guard let value = Environment.get(key), !value.isEmpty else {
                throw Abort(.internalServerError, reason: "\(key) is not set")
            }
            return value
        }
        var github: GitHubAppCredentials?
        if let appID = Environment.get("GITHUB_APP_ID"), let key = Environment.get("GITHUB_APP_PRIVATE_KEY") {
            github = GitHubAppCredentials(appID: appID, privateKeyPEM: key)
        }
        return Settings(
            webhookSecret: try require("GITHUB_WEBHOOK_SECRET"),
            agentTokens: Set(try require("AGENT_TOKENS").split(separator: ",").map(String.init)),
            runnerLabel: Environment.get("RUNNER_LABEL") ?? "maccheri",
            defaultImage: Environment.get("DEFAULT_IMAGE") ?? "macos-27-xcode-27.2",
            jobTimeoutSeconds: Environment.get("JOB_TIMEOUT_SECONDS").flatMap(Int.init) ?? 3600,
            github: github
        )
    }
}
