import Foundation
import os
import Synchronization

/// Logs to the unified log (`log show --predicate 'subsystem == "dev.maccheri.guestd"'`) and
/// appends the same lines to a file, which survives in the clone if the host keeps it.
public final class GuestLog: Sendable {
    private let logger = Logger(subsystem: "dev.maccheri.guestd", category: "guestd")
    private let file: Mutex<FileHandle?>

    public init(fileURL: URL?) {
        var handle: FileHandle?
        if let fileURL {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: fileURL)
            _ = try? handle?.seekToEnd()
        }
        file = Mutex(handle)
    }

    public func callAsFunction(_ message: String) {
        logger.log("\(message, privacy: .public)")
        let line = "\(Date().formatted(.iso8601)) \(message)\n"
        file.withLock { _ = try? $0?.write(contentsOf: Data(line.utf8)) }
    }
}
