import AgentCore
import Foundation
import MaccheriProtocol
import Observation
import ServiceManagement

/// Owns the in-process agent and mirrors its status for the menu bar. Virtualization.framework
/// needs the main run loop, which the app has, so the agent runs right here, not in a helper.
@Observable
final class HostModel {
    var settings = AppSettings.load() {
        didSet {
            settings.save()
            if settings.pool != oldValue.pool, let agent { Task { await agent.update(settings.pool) } }
        }
    }
    private(set) var status = AgentStatus()
    private(set) var credentials = AgentCredentials.load()
    private(set) var isRunning = false
    /// Why the agent isn't running, or the last enrollment error.
    private(set) var problem: String?
    private(set) var log: [String] = []

    private var agent: Agent?
    private var runTask: Task<Void, Never>?
    private var lock: WorkDirectoryLock?

    var isPaused: Bool { settings.paused }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                problem = String(localized: "Launch at login: \(error.localizedDescription)")
            }
        }
    }

    init() {
        if credentials != nil { start() }
    }

    // MARK: Enrollment

    func enroll(controlPlane: String, token: String) async {
        guard let url = URL(string: controlPlane.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else {
            problem = String(localized: "Enter the control plane address, e.g. https://maccheri.example.com")
            return
        }
        problem = nil
        do {
            let request = HostEnrollRequest(name: HostInventory.computerName, hardware: HostInventory.hardware())
            let enrollment = try await ControlPlaneClient.enroll(baseURL: url, userToken: token.trimmingCharacters(in: .whitespaces), request)
            let credentials = AgentCredentials(controlPlane: url, hostID: enrollment.hostID, agentToken: enrollment.agentToken)
            try credentials.save()
            self.credentials = credentials
            settings.controlPlane = url.absoluteString
            await stop()
            start()
        } catch {
            problem = String(localized: "Enrollment failed: \(String(describing: error))")
        }
    }

    func signOut() async {
        await stop()
        AgentCredentials.delete()
        credentials = nil
        status = AgentStatus()
    }

    // MARK: Agent

    func start() {
        guard agent == nil, let credentials else { return }
        let store = settings.store
        do {
            lock = try WorkDirectoryLock(workDirectory: store.workDirectory)
        } catch {
            problem = String(describing: error)
            return
        }
        for orphan in store.removeOrphans() { append("removed orphaned clone \(orphan)") }
        problem = nil

        let log: @Sendable (String) -> Void = { [weak self] line in
            print(line)
            Task { @MainActor in self?.append(line) }
        }
        let pool = VMPool(store: store, runner: VirtualizationRunner(log: log), settings: settings.pool, log: log)
        let agent = Agent(
            controlPlane: ControlPlaneClient(baseURL: credentials.controlPlane, token: credentials.agentToken),
            pool: pool,
            peer: SignalingStubPeer(log: log),
            log: log,
            onStatus: { [weak self] status in Task { @MainActor in self?.status = status } }
        )
        self.agent = agent
        isRunning = true
        let paused = settings.paused
        runTask = Task {
            if paused { await agent.setPaused(true) }
            await agent.run()
        }
    }

    /// Stops every VM and deletes its clone; returns when that is done.
    func stop() async {
        guard let runTask else { return }
        runTask.cancel()
        await runTask.value
        self.runTask = nil
        agent = nil
        lock = nil
        isRunning = false
        status.activities = []
    }

    /// Images or work directory changed: restart on the new paths.
    func restart() async {
        await stop()
        start()
    }

    func setPaused(_ paused: Bool) {
        settings.paused = paused
        guard let agent else { return }
        Task { await agent.setPaused(paused) }
    }

    func rescanImages() {
        guard let agent else { return }
        Task { await agent.rescanImages() }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}
