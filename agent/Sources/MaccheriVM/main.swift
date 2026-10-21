import AgentCore
import Foundation

// maccheri-vm --images DIR --work DIR --image NAME [--timeout SECONDS] [--keep] [--forward HOST:GUEST]...
//             [--session FILE] [--cpus N] [--memory-gb N]
// maccheri-vm --attach GUEST_IP --forward HOST:GUEST...
//
// Boots one throwaway clone of a base image exactly the way the agent does, without a control
// plane. The guest sits on the agent's isolated network (internet only), so the host reaches it
// only through `--forward`, which listens on all host interfaces: `--forward 2222:22` for SSH,
// `--forward 7300` for simstream. `--session` copies a `session.json` into the guest's share.
// `--attach` relays ports to a guest that is already running elsewhere (e.g. `tart run`).
func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func arguments(_ name: String) -> [String] {
    let args = CommandLine.arguments
    return args.indices.filter { args[$0] == name && $0 + 1 < args.count }.map { args[$0 + 1] }
}

let usage = """
    usage: maccheri-vm --images DIR --work DIR --image NAME [--timeout SECONDS] [--keep] [--forward HOST:GUEST]...
                       [--session FILE] [--cpus N] [--memory-gb N]
           maccheri-vm --attach GUEST_IP --forward HOST:GUEST...

    """
let mappings: [TCPForwarder.Mapping] = arguments("--forward").map { spec in
    guard let mapping = TCPForwarder.Mapping(spec) else {
        FileHandle.standardError.write(Data("bad --forward \(spec)\n\(usage)".utf8))
        exit(64)
    }
    return mapping
}
// Line-buffered even when redirected to a log file.
setvbuf(stdout, nil, _IOLBF, 0)

/// Started forwarders live as long as the process.
var forwarders: [TCPForwarder] = []

@MainActor
func startForwarding(to guest: String) async {
    for mapping in mappings {
        do {
            let forwarder = try TCPForwarder(mapping, guestHost: guest, log: { print($0) })
            try await forwarder.start()
            forwarders.append(forwarder)
            print("forwarding *:\(mapping.hostPort) → \(guest):\(mapping.guestPort)")
        } catch {
            print("forward \(mapping) failed: \(error)")
        }
    }
}

if let guest = argument("--attach") {
    guard !mappings.isEmpty else {
        FileHandle.standardError.write(Data("--attach needs at least one --forward\n\(usage)".utf8))
        exit(64)
    }
    Task { await startForwarding(to: guest) }
    dispatchMain()
}

guard let imagesPath = argument("--images"), let workPath = argument("--work"), let imageName = argument("--image") else {
    FileHandle.standardError.write(Data(usage.utf8))
    exit(64)
}
let timeout = Duration.seconds(argument("--timeout").flatMap(Int.init) ?? 3600)
let keep = CommandLine.arguments.contains("--keep")
var resources = VMResources()
resources.cpuCount = argument("--cpus").flatMap(Int.init)
resources.memorySize = argument("--memory-gb").flatMap(UInt64.init).map { $0 << 30 }

let store = ImageStore(imagesDirectory: URL(filePath: imagesPath), workDirectory: URL(filePath: workPath))
let base: VMBundle
do {
    base = try store.baseImage(named: imageName)
} catch {
    print("error: \(error)")
    exit(1)
}
let clone = try store.clone(base, jobID: UUID())
let shared = clone.url.appending(path: "shared", directoryHint: .isDirectory)
try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
if let session = argument("--session") {
    try FileManager.default.copyItem(at: URL(filePath: session), to: shared.appending(path: "session.json"))
}
print("clone: \(clone.url.path) (\(resources.cpuCount ?? base.config.cpuCount) CPU, \(resources.memory(for: base) >> 30) GB)")

func cleanUp() {
    if keep { print("kept \(clone.url.path)") } else { store.destroy(clone) }
}

// Ctrl-C: the VM dies with the process; just don't leave the clone behind.
signal(SIGINT, SIG_IGN)
let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupt.setEventHandler {
    cleanUp()
    exit(130)
}
interrupt.resume()

let runner = VirtualizationRunner(log: { print($0) })

Task { @MainActor in
    let started = ContinuousClock.now
    do {
        let vm = try await runner.start(clone, sharedDirectory: shared, resources: resources)
        let network = vm.guest as! GuestNetwork
        print("started; guest network \(network.configuration.guest) via \(network.configuration.gateway), internet only")
        for mapping in mappings {
            let port = try network.forward(guestPort: mapping.guestPort, hostPort: mapping.hostPort, on: .any)
            print("forwarding *:\(port) → guest:\(mapping.guestPort)")
        }
        Task {
            await network.waitForLease()
            print("guest took its DHCP lease after \(ContinuousClock.now - started)")
        }
        let exit = await Agent.waitForExit(vm, timeout: timeout)
        print("vm \(exit.map { "\($0)" } ?? "timed out") after \(ContinuousClock.now - started)")
        cleanUp()
        Foundation.exit(0)
    } catch {
        print("vm failed: \(error)")
        cleanUp()
        Foundation.exit(1)
    }
}
// VZVirtualMachine needs a running main run loop.
RunLoop.main.run()
