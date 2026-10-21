import AgentCore
import Foundation
import MaccheriProtocol

// maccheri-agent enroll --control-plane URL --user-token TOKEN [--name NAME]
// maccheri-agent run --images DIR --work DIR [--warm N] [--max-vms N] [--cpus N] [--memory-gb N]
//                    [--control-plane URL --token TOKEN]
//
// The headless agent. `enroll` registers this Mac with the owner's user token and keeps the agent
// token in the login keychain; `run` uses it (or `--token` / MACCHERI_AGENT_TOKEN) until stopped.
func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

let usage = """
    usage: maccheri-agent enroll --control-plane URL --user-token TOKEN [--name NAME]
           maccheri-agent run --images DIR --work DIR [--warm N] [--max-vms N] [--cpus N] [--memory-gb N]
                              [--control-plane URL --token TOKEN]

    """

func fail(_ message: String, code: Int32 = 64) -> Never {
    FileHandle.standardError.write(Data((message.hasSuffix("\n") ? message : message + "\n").utf8))
    exit(code)
}

// Line-buffered even when redirected to a log file.
setvbuf(stdout, nil, _IOLBF, 0)

switch CommandLine.arguments.dropFirst().first {
case "enroll":
    guard let controlPlane = argument("--control-plane").flatMap(URL.init(string:)),
          let userToken = argument("--user-token") ?? ProcessInfo.processInfo.environment["MACCHERI_USER_TOKEN"]
    else { fail(usage) }
    let request = HostEnrollRequest(name: argument("--name") ?? HostInventory.computerName, hardware: HostInventory.hardware())
    Task {
        do {
            let enrollment = try await ControlPlaneClient.enroll(baseURL: controlPlane, userToken: userToken, request)
            try AgentCredentials(controlPlane: controlPlane, hostID: enrollment.hostID, agentToken: enrollment.agentToken).save()
            print("enrolled \(request.name) as host \(enrollment.hostID); token saved to the keychain")
            exit(0)
        } catch {
            fail("enroll failed: \(error)", code: 1)
        }
    }
    dispatchMain()

case "run":
    guard let imagesPath = argument("--images"), let workPath = argument("--work") else { fail(usage) }
    let controlPlane: URL
    let token: String
    if let url = argument("--control-plane").flatMap(URL.init(string:)), let explicit = argument("--token") ?? ProcessInfo.processInfo.environment["MACCHERI_AGENT_TOKEN"] {
        (controlPlane, token) = (url, explicit)
    } else if let credentials = AgentCredentials.load() {
        (controlPlane, token) = (credentials.controlPlane, credentials.agentToken)
    } else {
        fail("not enrolled: run `maccheri-agent enroll` first, or pass --control-plane and --token\n\(usage)")
    }

    let store = ImageStore(imagesDirectory: URL(filePath: imagesPath), workDirectory: URL(filePath: workPath))
    let lock: WorkDirectoryLock
    do {
        lock = try WorkDirectoryLock(workDirectory: store.workDirectory)
    } catch {
        fail("\(error)", code: 1)
    }
    for orphan in store.removeOrphans() { print("removed orphaned clone \(orphan)") }

    var settings = PoolSettings()
    if let warm = argument("--warm").flatMap(Int.init) { settings.warmVMs = warm }
    if let max = argument("--max-vms").flatMap(Int.init) { settings.maxVMs = max }
    if let cpus = argument("--cpus").flatMap(Int.init) { settings.resources.cpuCount = cpus }
    if let gb = argument("--memory-gb").flatMap(UInt64.init) { settings.resources.memorySize = gb << 30 }

    let log: @Sendable (String) -> Void = { print($0) }
    let pool = VMPool(store: store, runner: VirtualizationRunner(log: log), settings: settings, log: log)
    let agent = Agent(controlPlane: ControlPlaneClient(baseURL: controlPlane, token: token), pool: pool, peer: SignalingStubPeer(log: log), log: log)
    print("maccheri-agent \(Agent.version): \(controlPlane), images \(imagesPath), work \(workPath)")

    let running = Task { await agent.run() }
    // Ctrl-C / SIGTERM: stop VMs and delete clones before exiting.
    var signals: [any DispatchSourceSignal] = []
    for code in [SIGINT, SIGTERM] {
        signal(code, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: code, queue: .main)
        source.setEventHandler {
            print("stopping…")
            running.cancel()
        }
        source.resume()
        signals.append(source)
    }
    Task {
        await running.value
        withExtendedLifetime(lock) {}
        exit(0)
    }
    // VZVirtualMachine needs a running main run loop.
    RunLoop.main.run()

default:
    fail(usage)
}
