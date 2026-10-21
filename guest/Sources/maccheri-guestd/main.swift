import Foundation
import GuestCore

// maccheri-guestd [--share DIR] [--metadata FILE] [--runner DIR] [--simstream PATH] [--logs DIR]
//                 [--no-shutdown] [--no-preboot]
//
// Runs as a LaunchAgent of the auto-logged-in user (the simulator needs the GUI session).
// See guest/README.md.
func argument(_ name: String) -> String? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
    return args[index + 1]
}

var options = GuestDaemon.Options()
if let share = argument("--share") { options.share = URL(filePath: share, directoryHint: .isDirectory) }
if let metadata = argument("--metadata") { options.metadata = URL(filePath: metadata) }
if let runner = argument("--runner") { options.runnerDirectory = URL(filePath: runner, directoryHint: .isDirectory) }
if let simstream = argument("--simstream") { options.simstream = simstream }
if let logs = argument("--logs") { options.logDirectory = URL(filePath: logs, directoryHint: .isDirectory) }
options.shutdownWhenDone = !CommandLine.arguments.contains("--no-shutdown")
options.preboot = !CommandLine.arguments.contains("--no-preboot")

let log = GuestLog(fileURL: options.logDirectory.appending(path: "guestd.log"))
await GuestDaemon(options: options, log: log).run()
