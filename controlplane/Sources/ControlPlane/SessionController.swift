import Fluent
import MaccheriProtocol
import Vapor

/// Simulator sessions for the viewer. See ``SessionAPI``.
struct SessionController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let user = routes.grouped(UserAuthMiddleware())
        user.post("v1", "sessions", use: create)
        user.get("v1", "sessions", ":id", use: get)
        user.delete("v1", "sessions", ":id", use: delete)
    }

    @Sendable
    func create(req: Request) async throws -> SessionInfo {
        let user = try req.auth.require(UserModel.self)
        let request = (req.body.data?.readableBytes ?? 0) > 0 ? try req.content.decode(CreateSessionRequest.self) : CreateSessionRequest()
        let maccheri = req.maccheri
        let settings = maccheri.settings
        let now = maccheri.now

        let active = try await SessionModel.query(on: req.db)
            .filter(\.$userID == user.id!)
            .filter(\.$state ~~ SessionState.active)
            .count()
        guard active < settings.maxSessionsPerUser else {
            throw Abort(.tooManyRequests, reason: "at most \(settings.maxSessionsPerUser) sessions at a time")
        }
        if let hostID = request.hostID, try await HostModel.find(hostID, on: req.db) == nil {
            throw Abort(.notFound, reason: "no such host")
        }

        let session = SessionModel(
            userID: user.id!,
            requestedDevice: request.device,
            requestedHostID: request.hostID,
            viewerToken: Tokens.make(Tokens.signaling),
            hostToken: Tokens.make(Tokens.signaling),
            createdAt: now,
            expiresAt: now.addingTimeInterval(TimeInterval(settings.sessionSeconds))
        )
        try await session.create(on: req.db)
        maccheri.workAvailable.notifyAll()
        req.logger.info("session queued", metadata: ["session": "\(session.id!)", "user": "\(user.id!)"])
        return try await Self.info(session, on: req.db, settings: settings)
    }

    @Sendable
    func get(req: Request) async throws -> SessionInfo {
        try await Self.info(try await ownSession(req), on: req.db, settings: req.maccheri.settings)
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let id = try await ownSession(req).id!
        let maccheri = req.maccheri
        let db = req.db
        let logger = req.logger
        try await maccheri.assignment.withLock {
            guard let session = try await SessionModel.find(id, on: db) else { return }
            try await Lifecycle.finish(session, .ended, message: "ended by user", on: db, maccheri: maccheri, logger: logger)
        }
        return .noContent
    }

    /// Someone else's session is 404, unless the caller is an admin.
    private func ownSession(_ req: Request) async throws -> SessionModel {
        let user = try req.auth.require(UserModel.self)
        guard let id = req.parameters.get("id", as: UUID.self),
              let session = try await SessionModel.find(id, on: req.db),
              session.userID == user.id || user.isAdmin
        else { throw Abort(.notFound) }
        return session
    }

    static func info(_ session: SessionModel, on db: any Database, settings: Settings) async throws -> SessionInfo {
        var hostName: String?
        if let hostID = session.hostID {
            hostName = try await HostModel.find(hostID, on: db)?.name
        }
        let connectable = session.state == .starting || session.state == .ready
        return SessionInfo(
            id: session.id!,
            state: session.state,
            device: session.device,
            hostID: session.hostID,
            hostName: hostName,
            createdAt: session.createdAt,
            expiresAt: session.expiresAt,
            signaling: connectable ? session.signalingInfo(for: .viewer, settings: settings) : nil,
            message: session.message
        )
    }
}

extension CreateSessionRequest: @retroactive Content {}
extension SessionInfo: @retroactive Content {}
