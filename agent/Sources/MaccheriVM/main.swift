import AgentCore
import Foundation

// maccheri-vm --images DIR --work DIR --image NAME [--timeout SECONDS] [--keep] [--forward HOST:GUEST]...
// maccheri-vm --attach GUEST_IP --forward HOST:GUEST...
//
// Boots one throwaway clone of a base image exactly the way the agent does, without a control
// plane, and prints how to SSH into it. For checking images and the VM setup by hand.
// `--forward` relays a TCP port on all host interfaces to the guest (vmnet NAT hides it from the
// LAN); `--attach` does only that, for a guest that is already running.
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

enum DHCPLeases {
    /// Finds the guest's address in the host's DHCP leases (vmnet's bootpd writes them there).
    /// bootpd drops leading zeros in each octet: `1,a:2b:...`.
    static func address(mac: String) -> String? {
        guard let leases = try? String(contentsOfFile: "/var/db/dhcpd_leases", encoding: .utf8) else { return nil }
        let wanted = mac.lowercased().split(separator: ":").map { String(Int($0, radix: 16) ?? -1, radix: 16) }.joined(separator: ":")
        for entry in leases.components(separatedBy: "}") {
            var ip: String?, hw: String?
            for line in entry.split(separator: "\n") {
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                if parts[0] == "ip_address" { ip = parts[1] }
                if parts[0] == "hw_address" { hw = parts[1].split(separator: ",").last.map(String.init) }
            }
            if hw == wanted, let ip { return ip }
        }
        return nil
    }
}

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
print("clone: \(clone.url.path) (\(base.config.cpuCount) CPU, \(base.config.memorySize >> 30) GB)")

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

let runner = VirtualizationRunner { mac in
    print("started, mac \(mac); waiting for a DHCP lease…")
    Task {
        let start = ContinuousClock.now
        while ContinuousClock.now - start < .seconds(300) {
            if let ip = DHCPLeases.address(mac: mac) {
                print("guest at \(ip) after \(ContinuousClock.now - start): ssh admin@\(ip)")
                await startForwarding(to: ip)
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        print("no lease after 5 min")
    }
}

Task { @MainActor in
    let started = ContinuousClock.now
    do {
        let exit = try await runner.run(clone, sharedDirectory: shared, timeout: timeout)
        print("vm \(exit) after \(ContinuousClock.now - started)")
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
