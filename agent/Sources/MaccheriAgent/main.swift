import AgentCore
import Foundation

// maccheri-agent --control-plane URL --token TOKEN --images DIR --work DIR [--label L]…
func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

func arguments(_ name: String) -> [String] {
    let args = CommandLine.arguments
    return args.indices.filter { args[$0] == name && $0 + 1 < args.count }.map { args[$0 + 1] }
}

guard let controlPlane = argument("--control-plane").flatMap(URL.init(string:)),
      let token = argument("--token") ?? ProcessInfo.processInfo.environment["MACCHERI_AGENT_TOKEN"],
      let imagesPath = argument("--images"),
      let workPath = argument("--work")
else {
    FileHandle.standardError.write(Data("usage: maccheri-agent --control-plane URL --token TOKEN --images DIR --work DIR [--label L]…\n".utf8))
    exit(64)
}

// Line-buffered even when redirected to a log file.
setvbuf(stdout, nil, _IOLBF, 0)
let labels = ["maccheri"] + arguments("--label")
let runner = JobRunner(
    source: ControlPlaneClient(baseURL: controlPlane, token: token),
    images: ImageStore(imagesDirectory: URL(filePath: imagesPath), workDirectory: URL(filePath: workPath)),
    vm: VirtualizationRunner { print("vm started, mac \($0)") },
    labels: labels
)

print("maccheri-agent: polling \(controlPlane) as \(labels)")
// One job at a time for now; Apple's license would allow two macOS VMs.
Task {
    while true {
        do {
            if try await !runner.runOnce() {
                try await Task.sleep(for: .seconds(5))
            }
        } catch {
            print("error: \(error)")
            try? await Task.sleep(for: .seconds(15))
        }
    }
}
// VZVirtualMachine needs a running main run loop.
RunLoop.main.run()
