import Vapor

func configure(_ app: Application, settings: Settings, provisioner: (any RunnerProvisioner)? = nil) throws {
    let provisioner = provisioner ?? settings.github.map { GitHubAppProvisioner(credentials: $0, client: app.client) }
    guard let provisioner else {
        throw Abort(.internalServerError, reason: "GITHUB_APP_ID and GITHUB_APP_PRIVATE_KEY are required")
    }
    let queue = JobQueue()

    try app.register(collection: WebhookController(secret: settings.webhookSecret, runnerLabel: settings.runnerLabel, queue: queue))
    try app.register(collection: AgentController(
        tokens: settings.agentTokens,
        queue: queue,
        provisioner: provisioner,
        image: settings.defaultImage,
        timeoutSeconds: settings.jobTimeoutSeconds
    ))
    app.get("healthz") { _ in "ok" }
}
