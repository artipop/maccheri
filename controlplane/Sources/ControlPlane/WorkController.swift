import Fluent
import MaccheriProtocol
import Vapor

/// The agent's long-poll for work, its session state reports and CI completions. See ``WorkAPI``,
/// and the legacy CI-only ``AgentAPI``.
struct WorkController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let agent = routes.grouped(AgentAuthMiddleware())
        agent.post("agent", "v1", "work", use: work)
        agent.post("agent", "v1", "sessions", ":id", "state", use: reportState)

        // Old agents authenticate with AGENT_TOKENS from the environment; keep until A moves to /work.
        let legacy = routes.grouped(AgentAuthMiddleware(allowLegacyTokens: true))
        legacy.post("agent", "v1", "lease", use: lease)
        legacy.post("agent", "v1", "jobs", ":id", "complete", use: complete)
    }

    @Sendable
    func work(req: Request) async throws -> Response {
        let host = try req.auth.require(HostModel.self)
        let request = try req.content.decode(LeaseRequest.self)
        let maccheri = req.maccheri
        let dispatcher = Dispatcher(db: req.db, maccheri: maccheri, logger: req.logger)
        let deadline = ContinuousClock.now + .seconds(maccheri.settings.longPollSeconds)

        while true {
            if let lease = try await maccheri.assignment.withLock({ try await dispatcher.nextWork(for: host, request: request) }) {
                return try await lease.encodeResponse(status: .ok, for: req)
            }
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { return Response(status: .noContent) }
            // Also re-check every second: a session's warm-host grace period runs out without any event.
            await maccheri.workAvailable.wait(timeout: min(remaining, .seconds(1)))
        }
    }

    @Sendable
    func reportState(req: Request) async throws -> HTTPStatus {
        let host = try req.auth.require(HostModel.self)
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        let report = try req.content.decode(SessionStateReport.self)
        let maccheri = req.maccheri
        let db = req.db
        let logger = req.logger

        return try await maccheri.assignment.withLock {
            guard let session = try await SessionModel.find(id, on: db), session.hostID == host.id else {
                throw Abort(.notFound)
            }
            guard session.isActive else {
                session.hostNotified = true
                try await session.update(on: db)
                return .gone
            }
            switch report.state {
            case .starting:
                break
            case .ready:
                guard session.state == .starting else { break }
                session.state = .ready
                session.readyAt = maccheri.now
                try await session.update(on: db)
                logger.info("session ready", metadata: ["session": "\(id)"])
            case .ended:
                try await Lifecycle.finish(session, .ended, message: report.message ?? "ended on the host", hostNotified: true, on: db, maccheri: maccheri, logger: logger)
            case .failed:
                try await Lifecycle.finish(session, .failed, message: report.message ?? "failed on the host", hostNotified: true, on: db, maccheri: maccheri, logger: logger)
            }
            return .noContent
        }
    }

    /// Legacy: CI only, answers at once.
    @Sendable
    func lease(req: Request) async throws -> Response {
        let request = try req.content.decode(LeaseRequest.self)
        guard request.freeSlots > 0 else { return Response(status: .noContent) }
        let host = req.auth.get(HostModel.self)
        let dispatcher = Dispatcher(db: req.db, maccheri: req.maccheri, logger: req.logger)
        guard let lease = try await req.maccheri.assignment.withLock({ try await dispatcher.nextJob(labels: request.labels, hostID: host?.id) })
        else { return Response(status: .noContent) }
        return try await lease.encodeResponse(status: .ok, for: req)
    }

    @Sendable
    func complete(req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        let result = try req.content.decode(CompleteRequest.self)
        let host = req.auth.get(HostModel.self)
        guard let job = try await CIJobModel.find(id, on: req.db), job.state == .leased,
              host == nil || job.hostID == host?.id
        else { throw Abort(.notFound) }
        job.state = .done
        job.outcome = result.outcome
        job.doneAt = req.maccheri.now
        try await job.update(on: req.db)
        req.logger.info("completed", metadata: [
            "job": "\(job.githubJobID)",
            "outcome": "\(result.outcome.rawValue)",
            "seconds": "\(Int(result.durationSeconds))",
        ])
        return .noContent
    }
}

extension WorkLease: @retroactive Content {}
extension SimulatorSessionLease: @retroactive Content {}
extension SessionStateReport: @retroactive Content {}
extension JobLease: @retroactive Content {}
extension LeaseRequest: @retroactive Content {}
extension CompleteRequest: @retroactive Content {}
