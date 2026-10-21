import Foundation

/// A child process whose exit can be awaited; cancelling the awaiting task terminates it.
/// `Process` is thread-safe for what is used here (run once, isRunning, terminate).
public final class Subprocess: @unchecked Sendable {
    public struct Failure: Error, CustomStringConvertible {
        public var command: String
        public var status: Int32
        public var output: String
        public var description: String { "\(command) exited with \(status): \(output.suffix(2000))" }
    }

    private let process: Process
    private let exit: Task<Int32, Never>
    public let command: String

    /// `output`: where stdout and stderr go; nil captures them for ``run(_:_:)``.
    public init(_ executable: String, _ arguments: [String], output: FileHandle? = nil, environment: [String: String]? = nil, currentDirectory: URL? = nil) throws {
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardInput = FileHandle.nullDevice
        if let output {
            process.standardOutput = output
            process.standardError = output
        }
        let (stream, continuation) = AsyncStream.makeStream(of: Int32.self)
        process.terminationHandler = { continuation.yield($0.terminationStatus); continuation.finish() }
        try process.run()
        self.process = process
        self.command = ([executable] + arguments).joined(separator: " ")
        self.exit = Task { await stream.first { _ in true } ?? -1 }
    }

    public var processIdentifier: Int32 { process.processIdentifier }
    public var isRunning: Bool { process.isRunning }

    public func terminate() {
        if process.isRunning { process.terminate() }
    }

    /// Exit status; terminates the child if the caller is cancelled.
    public func wait() async -> Int32 {
        await withTaskCancellationHandler {
            await exit.value
        } onCancel: {
            terminate()
        }
    }

    /// Runs to completion and returns stdout+stderr; throws on a non-zero exit.
    @discardableResult
    public static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        let pipe = Pipe()
        let child = try Subprocess(executable, arguments, output: pipe.fileHandleForWriting)
        try pipe.fileHandleForWriting.close()
        // Drain while the child runs, so a full pipe can't block it.
        let reader = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
        let status = await child.wait()
        let output = String(decoding: await reader.value, as: UTF8.self)
        try Task.checkCancellation()
        guard status == 0 else { throw Failure(command: child.command, status: status, output: output) }
        return output
    }
}
