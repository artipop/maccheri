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

    /// The error of the last ``enroll(controlPlane:token:)``, shown next to the form.
    private(set) var enrollmentError: String?

    /// `maccheri.example.com` or `http://192.168.1.10:8080/` → a base URL without a trailing slash.
    static func controlPlaneURL(_ text: String) -> URL? {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme, ["http", "https"].contains(scheme), url.host() != nil else { return nil }
        return url
    }

    /// Registers this Mac with the team's control plane and starts taking work.
    func enroll(controlPlane: String, token: String) async {
        guard let url = Self.controlPlaneURL(controlPlane) else {
            enrollmentError = String(localized: "Enter the server address, e.g. maccheri.example.com")
            return
        }
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        enrollmentError = nil
        do {
            let request = HostEnrollRequest(name: HostInventory.computerName, hardware: HostInventory.hardware())
            let enrollment = try await ControlPlaneClient.enroll(baseURL: url, userToken: token, request)
            let credentials = AgentCredentials(controlPlane: url, hostID: enrollment.hostID, agentToken: enrollment.agentToken)
            try credentials.save()
            self.credentials = credentials
            settings.controlPlane = url.absoluteString
            await stop()
            start()
        } catch {
            settings.controlPlane = url.absoluteString
            enrollmentError = Self.explain(error, url: url)
        }
    }

    private static func explain(_ error: any Error, url: URL) -> String {
        switch error {
        case ControlPlaneError.unauthorized:
            return String(localized: "The server did not accept the token.")
        case let ControlPlaneError.http(status, _) where status == 404:
            return String(localized: "\(url.host() ?? "") answered, but it isn't a Maccheri server (404).")
        case let error as URLError where [.cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut, .notConnectedToInternet, .networkConnectionLost].contains(error.code):
            return String(localized: "Can't reach \(url.host() ?? url.absoluteString): \(error.localizedDescription)")
        case let error as URLError where error.code == .secureConnectionFailed || error.code == .serverCertificateUntrusted:
            return String(localized: "Secure connection to \(url.host() ?? "") failed. For a server without HTTPS, type http:// in front of the address.")
        default:
            return String(localized: "Couldn't connect: \(String(describing: error))")
        }
    }

    /// Images in the images folder that can take work (built for Maccheri, with `maccheri.json`).
    var servableImages: [String] {
        settings.store.images().filter { $0.metadata != nil }.map(\.name)
    }

    func signOut() async {
        await stop()
        AgentCredentials.delete()
        credentials = nil
        status = AgentStatus()
        enrollmentError = nil
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
            peer: WebRTCPeer(log: log),
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
