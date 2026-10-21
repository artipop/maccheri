import Fluent
import FluentSQLiteDriver
import SQLKit
import Vapor

func configure(_ app: Application, settings: Settings, provisioner: (any RunnerProvisioner)? = nil, clock: AppClock = .system) async throws {
    // Contract: ISO 8601 dates (docs/contracts.md).
    ContentConfiguration.global.use(encoder: JSONEncoder.custom(dates: .iso8601), for: .json)
    ContentConfiguration.global.use(decoder: JSONDecoder.custom(dates: .iso8601), for: .json)

    // Same as Vapor's defaults, but errors are logged without the query string.
    app.middleware = Middlewares()
    app.middleware.use(RouteLoggingMiddleware(logLevel: .info))
    app.middleware.use(ErrorMiddleware.redacting(environment: app.environment))

    let provisioner = provisioner ?? settings.github.map { GitHubAppProvisioner(credentials: $0, client: app.client) }
    if provisioner == nil {
        app.logger.notice("GitHub App is not configured; CI jobs are not handed out")
    }
    let maccheri = Maccheri(settings: settings, clock: clock, provisioner: provisioner)
    app.maccheri = maccheri

    app.databases.use(.sqlite(.file(settings.databasePath)), as: .sqlite)
    app.migrations.add(CreateSchema())
    try await app.autoMigrate()
    if let sql = app.db as? any SQLDatabase {
        try await sql.raw("PRAGMA journal_mode=WAL").run()
    }
    if settings.sharedToken != nil {
        try await AuthController.ensureTeamUser(on: app.db, maccheri: maccheri)
    }
    if let code = settings.adminInvite {
        try await AuthController.ensureAdminInvite(code, on: app.db, maccheri: maccheri, logger: app.logger)
    }

    app.asyncCommands.use(CreateInviteCommand(), as: "create-invite")
    app.asyncCommands.use(BackupCommand(), as: "backup")
    app.lifecycle.use(SweepLifecycle())

    app.get("healthz") { _ in "ok" }
    if let secret = settings.webhookSecret {
        try app.register(collection: WebhookController(secret: secret, runnerLabel: settings.runnerLabel))
    }
    try app.register(collection: AuthController())
    try app.register(collection: HostController())
    try app.register(collection: SessionController())
    try app.register(collection: WorkController())
    try app.register(collection: SignalingController())
    if let directory = settings.publicDirectory {
        WebClient(directory: directory).register(on: app)
    }
}
