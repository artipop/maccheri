import Fluent
import SQLKit
import Vapor

/// `controlplane create-invite [--admin]`: prints a new invite code. The way to make the first admin.
struct CreateInviteCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Flag(name: "admin", help: "The new member becomes an admin.")
        var admin: Bool
    }

    var help: String { "Creates an invite and prints its code." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let invite = try await AuthController.createInvite(isAdmin: signature.admin, createdBy: nil, on: app.db, maccheri: app.maccheri)
        context.console.print(invite.code)
        context.console.print("expires \(invite.expiresAt.formatted(.iso8601))")
    }
}

/// `controlplane backup <file>`: consistent copy of the live database (`VACUUM INTO`).
struct BackupCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Argument(name: "file", help: "Where to write the copy; must not exist.")
        var file: String
    }

    var help: String { "Writes a consistent copy of the SQLite database." }

    func run(using context: CommandContext, signature: Signature) async throws {
        guard let sql = context.application.db as? any SQLDatabase else { throw Abort(.internalServerError, reason: "not an SQL database") }
        try await sql.raw("VACUUM INTO \(bind: signature.file)").run()
        context.console.print("backup written to \(signature.file)")
    }
}
