import Foundation

/// Agent ↔ control plane API, version 1.
///
/// The agent long-polls `POST /agent/v1/lease`; when a job is available the control plane
/// answers with a ``JobLease`` carrying a just-in-time runner config. After the VM is
/// destroyed the agent reports the outcome with `POST /agent/v1/jobs/{id}/complete`.
public enum AgentAPI {
    public static let leasePath = "/agent/v1/lease"
    public static func completePath(jobID: UUID) -> String { "/agent/v1/jobs/\(jobID.uuidString)/complete" }
}

public struct LeaseRequest: Codable, Sendable, Equatable {
    /// Labels this host can serve, e.g. `["maccheri", "macos-27", "xcode-27.2"]`.
    public var labels: [String]
    /// Number of VMs the host can start right now (Apple's license caps this at 2).
    public var freeSlots: Int

    public init(labels: [String], freeSlots: Int) {
        self.labels = labels
        self.freeSlots = freeSlots
    }
}

public struct JobLease: Codable, Sendable, Equatable {
    public var jobID: UUID
    /// GitHub `workflow_job.id`, for logs only.
    public var githubJobID: Int64
    public var repository: String
    /// Base image the VM must be cloned from.
    public var image: String
    /// `encoded_jit_config` from GitHub; passed verbatim to `run.sh --jitconfig`.
    public var jitConfig: String
    /// Hard limit after which the agent kills the VM.
    public var timeoutSeconds: Int

    public init(jobID: UUID, githubJobID: Int64, repository: String, image: String, jitConfig: String, timeoutSeconds: Int) {
        self.jobID = jobID
        self.githubJobID = githubJobID
        self.repository = repository
        self.image = image
        self.jitConfig = jitConfig
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum JobOutcome: String, Codable, Sendable {
    /// The VM ran and shut down by itself; the job result lives on GitHub.
    case finished
    case timedOut
    case vmFailed
}

public struct CompleteRequest: Codable, Sendable, Equatable {
    public var outcome: JobOutcome
    public var durationSeconds: Double
    public var message: String?

    public init(outcome: JobOutcome, durationSeconds: Double, message: String? = nil) {
        self.outcome = outcome
        self.durationSeconds = durationSeconds
        self.message = message
    }
}
