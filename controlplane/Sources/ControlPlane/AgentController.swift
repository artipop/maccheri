import MaccheriProtocol
import Vapor

/// Host agents poll here for work. See ``AgentAPI``.
struct AgentController: RouteCollection {
    let tokens: Set<String>
    let queue: JobQueue
    let provisioner: any RunnerProvisioner
    let image: String
    let timeoutSeconds: Int

    func boot(routes: any RoutesBuilder) throws {
        let agent = routes.grouped(AgentTokenMiddleware(tokens: tokens))
        agent.post("agent", "v1", "lease", use: lease)
        agent.post("agent", "v1", "jobs", ":id", "complete", use: complete)
    }

    @Sendable
    func lease(req: Request) async throws -> Response {
        let request = try req.content.decode(LeaseRequest.self)
        guard request.freeSlots > 0,
              let leased = await queue.lease(hostLabels: Set(request.labels.map { $0.lowercased() }))
        else { return Response(status: .noContent) }

        let jitConfig: String
        do {
            jitConfig = try await provisioner.jitConfig(
                installationID: leased.job.installationID,
                repository: leased.job.repository,
                runnerName: "maccheri-\(leased.id.uuidString.prefix(8).lowercased())",
                labels: leased.job.labels.filter { !GitHubDefaultLabels.all.contains($0) }
            )
        } catch {
            await queue.release(leased.id)
            req.logger.error("jit config failed", metadata: ["job": "\(leased.job.githubJobID)", "error": "\(error)"])
            throw Abort(.badGateway, reason: "could not provision runner")
        }

        let lease = JobLease(
            jobID: leased.id,
            githubJobID: leased.job.githubJobID,
            repository: leased.job.repository,
            image: image,
            jitConfig: jitConfig,
            timeoutSeconds: timeoutSeconds
        )
        return try await lease.encodeResponse(status: .ok, for: req)
    }

    @Sendable
    func complete(req: Request) async throws -> HTTPStatus {
        guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
        let result = try req.content.decode(CompleteRequest.self)
        guard let leased = await queue.complete(id) else { throw Abort(.notFound) }
        req.logger.info("completed", metadata: [
            "job": "\(leased.job.githubJobID)",
            "outcome": "\(result.outcome.rawValue)",
            "seconds": "\(Int(result.durationSeconds))",
        ])
        return .noContent
    }
}

extension JobLease: @retroactive Content {}
extension LeaseRequest: @retroactive Content {}
extension CompleteRequest: @retroactive Content {}

struct AgentTokenMiddleware: AsyncMiddleware {
    let tokens: Set<String>

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let token = request.headers.bearerAuthorization?.token, tokens.contains(token) else {
            throw Abort(.unauthorized)
        }
        return try await next.respond(to: request)
    }
}
