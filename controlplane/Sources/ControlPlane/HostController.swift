import Fluent
import MaccheriProtocol
import Vapor

/// Host enrollment, listing and heartbeats. See ``HostAPI``.
struct HostController: RouteCollection {
    /// How long an ended session keeps showing up in heartbeat responses.
    static let endedSessionsRetentionSeconds: TimeInterval = 600

    func boot(routes: any RoutesBuilder) throws {
        let user = routes.grouped(UserAuthMiddleware())
        user.post("v1", "hosts", "enroll", use: enroll)
        user.get("v1", "hosts", use: list)
        routes.grouped(AgentAuthMiddleware()).post("agent", "v1", "heartbeat", use: heartbeat)
    }

    @Sendable
    func enroll(req: Request) async throws -> HostEnrollment {
        let user = try req.auth.require(UserModel.self)
        let request = try req.content.decode(HostEnrollRequest.self)
        let name = request.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 64 else { throw Abort(.badRequest, reason: "name must be 1-64 characters") }

        let token = Tokens.make(Tokens.agent)
        let host = HostModel(ownerID: user.id!, name: name, hardware: request.hardware, agentTokenHash: Tokens.hash(token), createdAt: req.maccheri.now)
        try await host.create(on: req.db)
        req.logger.info("host enrolled", metadata: ["host": "\(host.id!)", "owner": "\(user.id!)"])
        return HostEnrollment(hostID: host.id!, agentToken: token)
    }

    /// Every host of the team: it's one pool.
    @Sendable
    func list(req: Request) async throws -> [HostInfo] {
        let hosts = try await HostModel.query(on: req.db).sort(\.$createdAt).all()
        let owners = try await UserModel.query(on: req.db).filter(\.$id ~~ Set(hosts.map(\.ownerID))).all()
        let names = Dictionary(uniqueKeysWithValues: owners.map { ($0.id!, $0.name) })
        let settings = req.maccheri.settings
        let now = req.maccheri.now
        return hosts.map { host in
            HostInfo(
                id: host.id!,
                name: host.name,
                ownerName: names[host.ownerID] ?? "",
                hardware: host.hardware,
                online: host.isOnline(at: now, offlineAfterSeconds: settings.offlineAfterSeconds),
                capacity: host.capacity
            )
        }
    }

    @Sendable
    func heartbeat(req: Request) async throws -> HeartbeatResponse {
        let host = try req.auth.require(HostModel.self)
        let heartbeat = try req.content.decode(Heartbeat.self)
        host.agentVersion = heartbeat.agentVersion
        host.capacity = heartbeat.capacity
        try await host.update(on: req.db)
        if heartbeat.capacity.freeSlots > 0 || heartbeat.capacity.warmVMs > 0 {
            req.maccheri.workAvailable.notifyAll() // a warm VM may change who should take a queued session
        }

        // Over on our side, and the agent hasn't said it knows (its own final report or a 410).
        // Repeated on every heartbeat for a while, since a lost response must not leave a VM running.
        let ended = try await SessionModel.query(on: req.db)
            .filter(\.$hostID == host.id!)
            .filter(\.$state ~~ [.ended, .failed])
            .filter(\.$hostNotified == false)
            .filter(\.$endedAt > req.maccheri.now.addingTimeInterval(-Self.endedSessionsRetentionSeconds))
            .all()
        return HeartbeatResponse(endedSessions: ended.map { $0.id! })
    }
}

extension HostModel: Authenticatable {}

/// `Authorization: Bearer <HostEnrollment.agentToken>`. Every agent call counts as a sign of life.
struct AgentAuthMiddleware: AsyncMiddleware {
    /// Also accept `AGENT_TOKENS` from the environment (legacy `/agent/v1/lease`); no host is logged in then.
    var allowLegacyTokens = false

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let token = request.headers.bearerAuthorization?.token else { throw Abort(.unauthorized) }
        if allowLegacyTokens, request.maccheri.settings.legacyAgentTokens.contains(token) {
            return try await next.respond(to: request)
        }
        guard let host = try await HostModel.query(on: request.db).filter(\.$agentTokenHash == Tokens.hash(token)).first()
        else { throw Abort(.unauthorized) }
        host.lastSeenAt = request.maccheri.now
        try await host.update(on: request.db)
        request.auth.login(host)
        return try await next.respond(to: request)
    }
}

extension HostEnrollRequest: @retroactive Content {}
extension HostEnrollment: @retroactive Content {}
extension HostInfo: @retroactive Content {}
extension Heartbeat: @retroactive Content {}
extension HeartbeatResponse: @retroactive Content {}
