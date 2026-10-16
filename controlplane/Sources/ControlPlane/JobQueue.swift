import Foundation

/// A `workflow_job` waiting for, or handed to, a host.
struct QueuedJob: Sendable, Equatable {
    var githubJobID: Int64
    var repository: String
    var installationID: Int64
    var labels: [String]
    var enqueuedAt: Date
}

struct LeasedJob: Sendable, Equatable {
    var id: UUID
    var job: QueuedJob
    var leasedAt: Date
}

/// In-memory queue; moves to Postgres once the control plane runs as more than one instance.
///
/// A JIT runner registered for one job may pick up any queued job with matching labels, so
/// the queue only tracks how many runners each set of labels needs, not exact pairings.
actor JobQueue {
    private var pending: [QueuedJob] = []
    private var leased: [UUID: LeasedJob] = [:]

    func enqueue(_ job: QueuedJob) {
        guard !pending.contains(where: { $0.githubJobID == job.githubJobID }),
              !leased.values.contains(where: { $0.job.githubJobID == job.githubJobID })
        else { return }
        pending.append(job)
    }

    /// Takes the oldest job whose labels the host can serve.
    func lease(hostLabels: Set<String>, now: Date = Date()) -> LeasedJob? {
        guard let index = pending.firstIndex(where: { job in
            Set(job.labels.map { $0.lowercased() }).subtracting(GitHubDefaultLabels.all).isSubset(of: hostLabels)
        }) else { return nil }
        let lease = LeasedJob(id: UUID(), job: pending.remove(at: index), leasedAt: now)
        leased[lease.id] = lease
        return lease
    }

    /// Puts a job back when provisioning its runner failed.
    func release(_ id: UUID) {
        guard let lease = leased.removeValue(forKey: id) else { return }
        pending.insert(lease.job, at: 0)
    }

    /// GitHub reported the job finished or cancelled; it no longer needs a runner.
    func githubJobCompleted(_ githubJobID: Int64) {
        pending.removeAll { $0.githubJobID == githubJobID }
    }

    @discardableResult
    func complete(_ id: UUID) -> LeasedJob? {
        leased.removeValue(forKey: id)
    }

    var pendingCount: Int { pending.count }
    var leasedCount: Int { leased.count }
}

enum GitHubDefaultLabels {
    /// Labels GitHub assigns to every self-hosted macOS arm64 runner on its own.
    static let all: Set<String> = ["self-hosted", "macos", "arm64"]
}
