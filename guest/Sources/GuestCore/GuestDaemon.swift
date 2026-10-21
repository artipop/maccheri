import Foundation
import MaccheriProtocol

/// Does exactly one thing per boot: waits for `session.json` in the share, runs one CI job or
/// serves one simulator session, and shuts the guest down.
public struct GuestDaemon: Sendable {
    public struct Options: Sendable {
        public var share = URL(filePath: GuestAPI.sharePath, directoryHint: .isDirectory)
        public var metadata = URL(filePath: ImageMetadata.guestPath)
        public var runnerDirectory = URL(filePath: NSHomeDirectory()).appending(path: "actions-runner", directoryHint: .isDirectory)
        public var simstream = "/usr/local/bin/simstream"
        public var logDirectory = URL(filePath: NSHomeDirectory()).appending(path: "Library/Logs/Maccheri", directoryHint: .isDirectory)
        /// Off for testing in a running guest: the daemon just exits.
        public var shutdownWhenDone = true
        /// Boot the image's default device while waiting, so a simulator session starts warm.
        public var preboot = true

        public init() {}
    }

    public let options: Options
    public let log: GuestLog
    public var simulators = Simulators()

    public init(options: Options, log: GuestLog) {
        self.options = options
        self.log = log
    }

    public func run() async {
        let metadata = try? ImageMetadata.load(from: options.metadata)
        log("guestd \(metadata?.guestVersion ?? "?"): waiting for \(options.share.appending(path: GuestAPI.sessionFile).path)")

        // A cold VM finds its session at once (the agent writes it before boot); pre-boot only for
        // a VM that waits in the pool, where it cannot know which kind of session comes next.
        let immediate = SessionSource.read(share: options.share)
        let preboot: Task<String?, Never>? = options.preboot && immediate == nil ? metadata?.devices.first.map { spec in
            Task { await prebootDevice(spec) }
        } : nil

        let session: GuestSession
        if let immediate {
            session = immediate
        } else {
            do {
                session = try await SessionSource.wait(share: options.share)
            } catch {
                return
            }
        }

        switch session {
        case let .ci(job):
            log("session: ci")
            if let preboot {
                preboot.cancel()
                _ = await preboot.value
                // A job gets the image as built, without a device left running.
                do { try await simulators.shutdownAll() } catch { log("simctl shutdown all: \(error)") }
            }
            await runJob(job)
        case let .simulator(request):
            log("session: simulator \(request.sessionID) \(request.device.deviceType) \(request.device.runtime) port \(request.simstreamPort)")
            let warm = await preboot?.value
            await serve(request, warm: warm)
        }
        await powerOff()
    }

    // MARK: - Pre-boot

    private func prebootDevice(_ spec: DeviceSpec) async -> String? {
        let started = ContinuousClock.now
        do {
            let udid = try await simulators.device(for: spec)
            try await simulators.boot(udid)
            log("pre-booted \(udid) in \(ContinuousClock.now - started)")
            return udid
        } catch {
            log(Task.isCancelled ? "pre-boot cancelled" : "pre-boot failed: \(error)")
            return nil
        }
    }

    // MARK: - CI

    private func runJob(_ job: GuestCIJob) async {
        let script = options.runnerDirectory.appending(path: "run.sh")
        do {
            let output = try logFile("actions-runner.log")
            let runner = try Subprocess(script.path, ["--jitconfig", job.jitConfig], output: output, currentDirectory: options.runnerDirectory)
            log("runner started, pid \(runner.processIdentifier)")
            let status = await runner.wait()
            log("runner exited with \(status)")
        } catch {
            log("runner failed to start: \(error)")
        }
    }

    // MARK: - Simulator

    private func serve(_ request: GuestSimulatorSession, warm: String?) async {
        let started = ContinuousClock.now
        let udid: String
        do {
            udid = try await simulators.device(for: request.device)
            if let warm, warm != udid {
                try? await simulators.shutdown(warm)
            }
            try await simulators.boot(udid)
            log("device \(udid) booted after \(ContinuousClock.now - started)")
        } catch {
            log("device for \(request.device) failed: \(error)")
            return
        }

        let simstream: Subprocess
        do {
            let output = try logFile("simstream.log")
            simstream = try Subprocess(options.simstream, ["--udid", udid, "--port", String(request.simstreamPort)], output: output)
        } catch {
            log("simstream failed to start: \(error)")
            return
        }
        log("simstream started, pid \(simstream.processIdentifier)")
        if await Self.waitForListener(port: request.simstreamPort, while: { simstream.isRunning }) {
            log("simstream listening on :\(request.simstreamPort) after \(ContinuousClock.now - started)")
        }

        // The session is over when simstream exits or the host takes the hand-off away.
        let sessionFile = options.share.appending(path: GuestAPI.sessionFile)
        while simstream.isRunning {
            if !FileManager.default.fileExists(atPath: sessionFile.path) {
                log("\(sessionFile.path) is gone; ending the session")
                simstream.terminate()
                break
            }
            try? await Task.sleep(for: .seconds(1))
        }
        log("simstream exited with \(await simstream.wait())")
    }

    /// Polls a loopback connect until something accepts on `port`.
    static func waitForListener(port: UInt16, timeout: Duration = .seconds(60), while alive: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline, alive() {
            if canConnect(port: port) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }

    static func canConnect(port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    // MARK: -

    private func logFile(_ name: String) throws -> FileHandle {
        let url = options.logDirectory.appending(path: name)
        try FileManager.default.createDirectory(at: options.logDirectory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    private func powerOff() async {
        guard options.shutdownWhenDone else {
            log("done; not shutting down (--no-shutdown)")
            return
        }
        log("shutting down")
        do {
            try await Subprocess.run("/usr/bin/sudo", ["-n", "/sbin/shutdown", "-h", "now"])
        } catch {
            log("shutdown failed: \(error)")
        }
    }
}
