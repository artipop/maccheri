import Fluent
import MaccheriProtocol
import Vapor

/// Invites and user tokens. See ``AuthAPI``.
struct AuthController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.post("v1", "auth", "redeem", use: redeem)
        let user = routes.grouped(UserAuthMiddleware())
        user.post("v1", "invites", use: createInvite)
        user.get("v1", "me", use: me)
    }

    @Sendable
    func createInvite(req: Request) async throws -> Invite {
        let user = try req.auth.require(UserModel.self)
        guard user.isAdmin else { throw Abort(.forbidden, reason: "only admins create invites") }
        return try await Self.createInvite(isAdmin: false, createdBy: user.id, on: req.db, maccheri: req.maccheri)
    }

    @Sendable
    func redeem(req: Request) async throws -> UserToken {
        let request = try req.content.decode(RedeemInviteRequest.self)
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64 else { throw Abort(.badRequest, reason: "name must be 1-64 characters") }
        let maccheri = req.maccheri
        let now = maccheri.now
        let hash = Tokens.hash(request.code.trimmingCharacters(in: .whitespacesAndNewlines))
        let db = req.db

        return try await maccheri.assignment.withLock {
            guard let invite = try await InviteModel.query(on: db).filter(\.$codeHash == hash).first(),
                  invite.usedAt == nil, invite.expiresAt > now
            else { throw Abort(.notFound, reason: "invite not found, used or expired") }

            let token = Tokens.make(Tokens.user)
            let user = UserModel(name: name, isAdmin: invite.isAdmin, createdAt: now)
            try await db.transaction { db in
                try await user.create(on: db)
                invite.usedAt = now
                invite.usedBy = user.id
                try await invite.update(on: db)
                try await UserTokenModel(userID: user.id!, tokenHash: Tokens.hash(token), createdAt: now).create(on: db)
            }
            req.logger.info("invite redeemed", metadata: ["user": "\(user.id!)", "admin": "\(user.isAdmin)"])
            return UserToken(userID: user.id!, token: token)
        }
    }

    @Sendable
    func me(req: Request) async throws -> UserInfo {
        try req.auth.require(UserModel.self).info
    }

    static func createInvite(code: String? = nil, isAdmin: Bool, createdBy: UUID?, on db: any Database, maccheri: Maccheri) async throws -> Invite {
        let code = code ?? Tokens.make(Tokens.invite, bytes: 16)
        let expiresAt = maccheri.now.addingTimeInterval(TimeInterval(maccheri.settings.inviteTTLSeconds))
        try await InviteModel(codeHash: Tokens.hash(code), isAdmin: isAdmin, createdBy: createdBy, expiresAt: expiresAt).create(on: db)
        return Invite(code: code, expiresAt: expiresAt)
    }

    /// The user behind ``Settings/sharedToken``.
    static let teamUserID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    static func ensureTeamUser(on db: any Database, maccheri: Maccheri) async throws {
        guard try await UserModel.find(teamUserID, on: db) == nil else { return }
        let user = UserModel(name: "team", isAdmin: true, createdAt: maccheri.now)
        user.id = teamUserID
        try await user.create(on: db)
    }

    /// `ADMIN_INVITE`: makes sure the first admin can sign up.
    static func ensureAdminInvite(_ code: String, on db: any Database, maccheri: Maccheri, logger: Logger) async throws {
        guard try await UserModel.query(on: db).filter(\.$isAdmin == true).count() == 0 else { return }
        let hash = Tokens.hash(code)
        if let existing = try await InviteModel.query(on: db).filter(\.$codeHash == hash).first() {
            guard existing.usedAt == nil else { return }
            existing.isAdmin = true
            existing.expiresAt = maccheri.now.addingTimeInterval(TimeInterval(maccheri.settings.inviteTTLSeconds))
            try await existing.update(on: db)
        } else {
            _ = try await createInvite(code: code, isAdmin: true, createdBy: nil, on: db, maccheri: maccheri)
        }
        logger.notice("ADMIN_INVITE is active until the first admin signs up")
    }
}

extension UserModel: Authenticatable {}

/// `Authorization: Bearer <UserToken.token>`, or the team's shared token.
struct UserAuthMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let token = request.headers.bearerAuthorization?.token else { throw Abort(.unauthorized) }
        if let shared = request.maccheri.settings.sharedToken, Tokens.constantTimeEqual(token, shared),
           let team = try await UserModel.find(AuthController.teamUserID, on: request.db) {
            request.auth.login(team)
            return try await next.respond(to: request)
        }
        guard let record = try await UserTokenModel.query(on: request.db).filter(\.$tokenHash == Tokens.hash(token)).first(),
              let user = try await UserModel.find(record.userID, on: request.db)
        else { throw Abort(.unauthorized) }

        let now = request.maccheri.now
        if record.lastUsedAt.map({ now.timeIntervalSince($0) > 60 }) ?? true {
            record.lastUsedAt = now
            try await record.update(on: request.db)
        }
        request.auth.login(user)
        return try await next.respond(to: request)
    }
}

extension Invite: @retroactive Content {}
extension RedeemInviteRequest: @retroactive Content {}
extension UserToken: @retroactive Content {}
extension UserInfo: @retroactive Content {}
