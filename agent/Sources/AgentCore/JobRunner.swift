import Foundation
import MaccheriProtocol

/// One iteration of the agent: lease → clone → boot with the JIT config → destroy → report.
public struct JobRunner: Sendable {
    public let source: any JobSource
    public let images: ImageStore
    public let vm: any VMRunner
    public let labels: [String]
    public let log: @Sendable (String) -> Void

    public init(source: any JobSource, images: ImageStore, vm: any VMRunner, labels: [String], log: @escaping @Sendable (String) -> Void = { print($0) }) {
        self.source = source
        self.images = images
        self.vm = vm
        self.labels = labels
        self.log = log
    }

    /// Returns `false` when there was nothing to do.
    @discardableResult
    public func runOnce() async throws -> Bool {
        guard let lease = try await source.lease(LeaseRequest(labels: labels, freeSlots: 1)) else { return false }
        log("job \(lease.jobID) (GitHub \(lease.githubJobID), \(lease.repository)) on \(lease.image)")

        let started = ContinuousClock.now
        let outcome: JobOutcome
        var message: String?
        do {
            outcome = try await execute(lease)
        } catch {
            outcome = .vmFailed
            message = String(describing: error)
            log("job \(lease.jobID) failed: \(error)")
        }
        let elapsed = ContinuousClock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        try await source.complete(jobID: lease.jobID, CompleteRequest(outcome: outcome, durationSeconds: seconds, message: message))
        log("job \(lease.jobID) \(outcome.rawValue) in \(Int(seconds))s")
        return true
    }

    private func execute(_ lease: JobLease) async throws -> JobOutcome {
        let base = try images.baseImage(named: lease.image)
        let clone = try images.clone(base, jobID: lease.jobID)
        defer { images.destroy(clone) }

        // The guest reads the JIT config from the read-only share and deletes nothing on the host.
        let shared = clone.url.appending(path: "shared", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        try Data(lease.jitConfig.utf8).write(to: shared.appending(path: "jitconfig"), options: .withoutOverwriting)

        switch try await vm.run(clone, sharedDirectory: shared, timeout: .seconds(lease.timeoutSeconds)) {
        case .guestStopped: return .finished
        case .timedOut: return .timedOut
        }
    }
}
