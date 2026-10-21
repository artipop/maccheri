import Fluent
import Foundation
import MaccheriProtocol

// Tables are described in DESIGN.md. Foreign keys are plain UUID fields: nothing here needs
// Fluent's eager loading, and plain fields keep the queries obvious.

final class UserModel: Model, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    @Field(key: "is_admin") var isAdmin: Bool
    @Field(key: "created_at") var createdAt: Date

    init() {}

    init(name: String, isAdmin: Bool, createdAt: Date) {
        self.name = name
        self.isAdmin = isAdmin
        self.createdAt = createdAt
    }

    var info: UserInfo { UserInfo(id: id!, name: name, isAdmin: isAdmin) }
}

final class UserTokenModel: Model, @unchecked Sendable {
    static let schema = "user_tokens"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "token_hash") var tokenHash: String
    @Field(key: "created_at") var createdAt: Date
    @OptionalField(key: "last_used_at") var lastUsedAt: Date?

    init() {}

    init(userID: UUID, tokenHash: String, createdAt: Date) {
        self.userID = userID
        self.tokenHash = tokenHash
        self.createdAt = createdAt
    }
}

final class InviteModel: Model, @unchecked Sendable {
    static let schema = "invites"

    @ID(key: .id) var id: UUID?
    @Field(key: "code_hash") var codeHash: String
    @Field(key: "is_admin") var isAdmin: Bool
    @OptionalField(key: "created_by") var createdBy: UUID?
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "used_at") var usedAt: Date?
    @OptionalField(key: "used_by") var usedBy: UUID?

    init() {}

    init(codeHash: String, isAdmin: Bool, createdBy: UUID?, expiresAt: Date) {
        self.codeHash = codeHash
        self.isAdmin = isAdmin
        self.createdBy = createdBy
        self.expiresAt = expiresAt
    }
}

final class HostModel: Model, @unchecked Sendable {
    static let schema = "hosts"

    @ID(key: .id) var id: UUID?
    @Field(key: "owner_id") var ownerID: UUID
    @Field(key: "name") var name: String
    @Field(key: "hardware") var hardware: HostHardware
    @Field(key: "agent_token_hash") var agentTokenHash: String
    @OptionalField(key: "agent_version") var agentVersion: String?
    @OptionalField(key: "capacity") var capacity: HostCapacity?
    @OptionalField(key: "last_seen_at") var lastSeenAt: Date?
    @Field(key: "created_at") var createdAt: Date

    init() {}

    init(ownerID: UUID, name: String, hardware: HostHardware, agentTokenHash: String, createdAt: Date) {
        self.ownerID = ownerID
        self.name = name
        self.hardware = hardware
        self.agentTokenHash = agentTokenHash
        self.createdAt = createdAt
    }

    func isOnline(at now: Date, offlineAfterSeconds: Int) -> Bool {
        guard let lastSeenAt else { return false }
        return now.timeIntervalSince(lastSeenAt) <= TimeInterval(offlineAfterSeconds)
    }
}

final class SessionModel: Model, @unchecked Sendable {
    static let schema = "sessions"

    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "state") var state: SessionState
    @OptionalField(key: "requested_device") var requestedDevice: DeviceSpec?
    @OptionalField(key: "requested_host_id") var requestedHostID: UUID?
    @OptionalField(key: "device") var device: DeviceSpec?
    @OptionalField(key: "host_id") var hostID: UUID?
    @OptionalField(key: "image") var image: String?
    @Field(key: "viewer_token") var viewerToken: String
    @Field(key: "host_token") var hostToken: String
    @Field(key: "created_at") var createdAt: Date
    @OptionalField(key: "leased_at") var leasedAt: Date?
    @OptionalField(key: "ready_at") var readyAt: Date?
    @OptionalField(key: "ended_at") var endedAt: Date?
    @Field(key: "expires_at") var expiresAt: Date
    @OptionalField(key: "message") var message: String?
    /// The agent knows the session is over, so heartbeats stop listing it.
    @Field(key: "host_notified") var hostNotified: Bool

    init() {}

    init(userID: UUID, requestedDevice: DeviceSpec?, requestedHostID: UUID?, viewerToken: String, hostToken: String, createdAt: Date, expiresAt: Date) {
        self.userID = userID
        self.state = .queued
        self.requestedDevice = requestedDevice
        self.requestedHostID = requestedHostID
        self.viewerToken = viewerToken
        self.hostToken = hostToken
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.hostNotified = false
    }

    var isActive: Bool { SessionState.active.contains(state) }

    func token(for role: SignalingRole) -> String {
        switch role {
        case .viewer: viewerToken
        case .host: hostToken
        }
    }
}

extension SessionState {
    static let active: [SessionState] = [.queued, .starting, .ready]
}

enum CIJobState: String, Codable, Sendable {
    case pending, leased, done
}

final class CIJobModel: Model, @unchecked Sendable {
    static let schema = "ci_jobs"

    @ID(key: .id) var id: UUID?
    @Field(key: "github_job_id") var githubJobID: Int64
    @Field(key: "repository") var repository: String
    @Field(key: "installation_id") var installationID: Int64
    /// Lowercased `runs-on` labels.
    @Field(key: "labels") var labels: [String]
    @Field(key: "state") var state: CIJobState
    @OptionalField(key: "host_id") var hostID: UUID?
    @Field(key: "enqueued_at") var enqueuedAt: Date
    @OptionalField(key: "leased_at") var leasedAt: Date?
    @OptionalField(key: "done_at") var doneAt: Date?
    @OptionalField(key: "outcome") var outcome: JobOutcome?

    init() {}

    init(githubJobID: Int64, repository: String, installationID: Int64, labels: [String], enqueuedAt: Date) {
        self.githubJobID = githubJobID
        self.repository = repository
        self.installationID = installationID
        self.labels = labels
        self.state = .pending
        self.enqueuedAt = enqueuedAt
    }

    /// The labels a host must serve: GitHub's own defaults don't count.
    var requiredLabels: Set<String> { Set(labels).subtracting(GitHubDefaultLabels.all) }
}

enum GitHubDefaultLabels {
    /// Labels GitHub assigns to every self-hosted macOS arm64 runner on its own.
    static let all: Set<String> = ["self-hosted", "macos", "arm64"]
}

struct CreateSchema: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UserModel.schema)
            .id()
            .field("name", .string, .required)
            .field("is_admin", .bool, .required)
            .field("created_at", .datetime, .required)
            .create()
        try await database.schema(UserTokenModel.schema)
            .id()
            .field("user_id", .uuid, .required, .references(UserModel.schema, .id, onDelete: .cascade))
            .field("token_hash", .string, .required)
            .field("created_at", .datetime, .required)
            .field("last_used_at", .datetime)
            .unique(on: "token_hash")
            .create()
        try await database.schema(InviteModel.schema)
            .id()
            .field("code_hash", .string, .required)
            .field("is_admin", .bool, .required)
            .field("created_by", .uuid)
            .field("expires_at", .datetime, .required)
            .field("used_at", .datetime)
            .field("used_by", .uuid)
            .unique(on: "code_hash")
            .create()
        try await database.schema(HostModel.schema)
            .id()
            .field("owner_id", .uuid, .required, .references(UserModel.schema, .id))
            .field("name", .string, .required)
            .field("hardware", .json, .required)
            .field("agent_token_hash", .string, .required)
            .field("agent_version", .string)
            .field("capacity", .json)
            .field("last_seen_at", .datetime)
            .field("created_at", .datetime, .required)
            .unique(on: "agent_token_hash")
            .create()
        try await database.schema(SessionModel.schema)
            .id()
            .field("user_id", .uuid, .required, .references(UserModel.schema, .id))
            .field("state", .string, .required)
            .field("requested_device", .json)
            .field("requested_host_id", .uuid)
            .field("device", .json)
            .field("host_id", .uuid)
            .field("image", .string)
            .field("viewer_token", .string, .required)
            .field("host_token", .string, .required)
            .field("created_at", .datetime, .required)
            .field("leased_at", .datetime)
            .field("ready_at", .datetime)
            .field("ended_at", .datetime)
            .field("expires_at", .datetime, .required)
            .field("message", .string)
            .field("host_notified", .bool, .required)
            .create()
        try await database.schema(CIJobModel.schema)
            .id()
            .field("github_job_id", .int64, .required)
            .field("repository", .string, .required)
            .field("installation_id", .int64, .required)
            .field("labels", .json, .required)
            .field("state", .string, .required)
            .field("host_id", .uuid)
            .field("enqueued_at", .datetime, .required)
            .field("leased_at", .datetime)
            .field("done_at", .datetime)
            .field("outcome", .string)
            .unique(on: "github_job_id")
            .create()
    }

    func revert(on database: any Database) async throws {
        for schema in [CIJobModel.schema, SessionModel.schema, HostModel.schema, InviteModel.schema, UserTokenModel.schema, UserModel.schema] {
            try await database.schema(schema).delete()
        }
    }
}
