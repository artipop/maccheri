import Crypto
import Vapor

/// Receives GitHub App webhooks. Only `workflow_job` matters for now.
struct WebhookController: RouteCollection {
    let secret: String
    let runnerLabel: String
    let queue: JobQueue

    func boot(routes: any RoutesBuilder) throws {
        routes.on(.POST, "github", "webhook", body: .collect(maxSize: "1mb"), use: receive)
    }

    @Sendable
    func receive(req: Request) async throws -> HTTPStatus {
        guard let body = req.body.data else { throw Abort(.badRequest) }
        let payload = Data(buffer: body)
        guard Self.isValidSignature(req.headers.first(name: "X-Hub-Signature-256"), payload: payload, secret: secret) else {
            throw Abort(.unauthorized, reason: "bad signature")
        }
        guard req.headers.first(name: "X-GitHub-Event") == "workflow_job" else { return .accepted }

        let event = try JSONDecoder().decode(WorkflowJobEvent.self, from: payload)
        let labels = event.workflowJob.labels.map { $0.lowercased() }
        guard labels.contains(runnerLabel.lowercased()) else { return .accepted }
        guard let installation = event.installation?.id else {
            throw Abort(.unprocessableEntity, reason: "workflow_job without installation")
        }

        switch event.action {
        case "queued":
            await queue.enqueue(QueuedJob(
                githubJobID: event.workflowJob.id,
                repository: event.repository.fullName,
                installationID: installation,
                labels: labels,
                enqueuedAt: Date()
            ))
            req.logger.info("queued", metadata: ["job": "\(event.workflowJob.id)", "repo": "\(event.repository.fullName)"])
        case "completed":
            await queue.githubJobCompleted(event.workflowJob.id)
        default:
            break
        }
        return .accepted
    }

    static func isValidSignature(_ header: String?, payload: Data, secret: String) -> Bool {
        guard let header, header.hasPrefix("sha256="), let expected = Data(hexString: String(header.dropFirst(7))) else {
            return false
        }
        return HMAC<SHA256>.isValidAuthenticationCode(expected, authenticating: payload, using: SymmetricKey(data: Data(secret.utf8)))
    }
}

struct WorkflowJobEvent: Decodable {
    struct Job: Decodable {
        var id: Int64
        var labels: [String]
    }
    struct Repository: Decodable {
        var fullName: String
        enum CodingKeys: String, CodingKey { case fullName = "full_name" }
    }
    struct Installation: Decodable {
        var id: Int64
    }

    var action: String
    var workflowJob: Job
    var repository: Repository
    var installation: Installation?

    enum CodingKeys: String, CodingKey {
        case action, repository, installation
        case workflowJob = "workflow_job"
    }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
