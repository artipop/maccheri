import Fluent
import MaccheriProtocol
import Vapor

/// Session end and the periodic sweep (DESIGN.md, "Фоновая проверка"). Callers hold
/// ``Maccheri/assignment`` so a sweep never races a lease or a state report.
enum Lifecycle {
    static let ciPendingLimitSeconds: TimeInterval = 86_400

    /// Moves a session to `ended` or `failed`, tells both signaling peers and closes their sockets.
    static func finish(_ session: SessionModel, _ state: SessionState, message: String?, hostNotified: Bool = false, on db: any Database, maccheri: Maccheri, logger: Logger) async throws {
        precondition(state == .ended || state == .failed)
        guard session.isActive else { return }
        session.state = state
        session.message = message
        session.endedAt = maccheri.now
        // Nobody to tell if no host ever took it.
        session.hostNotified = hostNotified || session.hostID == nil
        try await session.update(on: db)
        maccheri.signaling.end(session: session.id!, reason: message)
        logger.info("session \(state.rawValue)", metadata: ["session": "\(session.id!)", "reason": "\(message ?? "")"])
    }

    static func sweep(on db: any Database, maccheri: Maccheri, logger: Logger) async throws {
        let settings = maccheri.settings
        let now = maccheri.now
        let onlineCutoff = now.addingTimeInterval(-TimeInterval(settings.offlineAfterSeconds))

        let sessions = try await SessionModel.query(on: db).filter(\.$state ~~ SessionState.active).all()
        let hostIDs = Set(sessions.compactMap(\.hostID))
        let hosts = try await HostModel.query(on: db).filter(\.$id ~~ hostIDs).all()
        let online = Set(hosts.filter { $0.isOnline(at: now, offlineAfterSeconds: settings.offlineAfterSeconds) }.map { $0.id! })

        for session in sessions {
            if session.expiresAt <= now {
                try await finish(session, .ended, message: "expired", on: db, maccheri: maccheri, logger: logger)
            } else if session.state == .queued, now.timeIntervalSince(session.createdAt) > TimeInterval(settings.sessionQueueSeconds) {
                try await finish(session, .failed, message: "no host available", on: db, maccheri: maccheri, logger: logger)
            } else if let hostID = session.hostID, !online.contains(hostID) {
                try await finish(session, .failed, message: "host went offline", on: db, maccheri: maccheri, logger: logger)
            } else if session.state == .starting, let leasedAt = session.leasedAt,
                      now.timeIntervalSince(leasedAt) > TimeInterval(settings.sessionStartSeconds) {
                try await finish(session, .failed, message: "host did not start the session", on: db, maccheri: maccheri, logger: logger)
            }
        }

        // A runner registered for a job on a host that vanished never runs; let another host take it.
        let leased = try await CIJobModel.query(on: db).filter(\.$state == .leased).all()
        let jobHosts = try await HostModel.query(on: db).filter(\.$id ~~ Set(leased.compactMap(\.hostID))).all()
        let offlineJobHosts = Set(jobHosts.filter { ($0.lastSeenAt ?? .distantPast) < onlineCutoff }.map { $0.id! })
        var requeued = false
        for job in leased where job.hostID.map(offlineJobHosts.contains) ?? false {
            job.state = .pending
            job.hostID = nil
            job.leasedAt = nil
            try await job.update(on: db)
            requeued = true
            logger.warning("job requeued, host went offline", metadata: ["job": "\(job.githubJobID)"])
        }
        try await CIJobModel.query(on: db)
            .filter(\.$state == .pending)
            .filter(\.$enqueuedAt < now.addingTimeInterval(-ciPendingLimitSeconds))
            .set(\.$state, to: .done)
            .set(\.$doneAt, to: now)
            .update()
        if requeued { maccheri.workAvailable.notifyAll() }
    }
}

/// Runs ``Lifecycle/sweep(on:maccheri:logger:)`` every ``Settings/sweepSeconds``.
struct SweepLifecycle: LifecycleHandler {
    final class Box: @unchecked Sendable { var task: Task<Void, Never>? }
    let box = Box()

    func didBootAsync(_ app: Application) async throws {
        guard let seconds = app.maccheri.settings.sweepSeconds else { return }
        let maccheri = app.maccheri
        let db = app.db
        let logger = app.logger
        box.task = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(seconds))
                do {
                    try await maccheri.assignment.withLock {
                        try await Lifecycle.sweep(on: db, maccheri: maccheri, logger: logger)
                    }
                } catch {
                    logger.report(error: error)
                }
            }
        }
    }

    func shutdownAsync(_ app: Application) async {
        box.task?.cancel()
        await box.task?.value
    }
}
