import Foundation
import SimStreamProtocol

/// A zipped `.app` arriving in chunks: written to a temporary file, then unzipped, installed with
/// `simctl install` and launched. Status goes back to the client as it happens.
final class AppUpload: @unchecked Sendable {
    private let name: String
    private let size: UInt64
    private let udid: String
    private let report: @Sendable (InstallStatus) -> Void
    private let directory: URL
    private let file: FileHandle?
    private var received: UInt64 = 0
    private var lastReported: UInt64 = 0
    private static let work = DispatchQueue(label: "app-install")

    init(name: String, size: UInt64, udid: String, report: @escaping @Sendable (InstallStatus) -> Void) {
        self.name = name
        self.size = size
        self.udid = udid
        self.report = report
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("simstream-upload-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("upload.zip").path
        FileManager.default.createFile(atPath: path, contents: nil)
        file = FileHandle(forWritingAtPath: path)
        print("upload \(name), \(size) bytes")
        report(InstallStatus(state: .receiving, message: name))
    }

    func append(_ data: Data) {
        file?.write(data)
        received += UInt64(data.count)
    }

    func cancel() {
        try? file?.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func finish() {
        try? file?.close()
        let (directory, udid, size, received, report, name) = (directory, udid, size, received, report, name)
        Self.work.async {
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                guard received == size else { throw UploadError("got \(received) of \(size) bytes") }
                report(InstallStatus(state: .installing, message: name))
                let unpacked = directory.appendingPathComponent("unpacked")
                try Self.run("/usr/bin/ditto", ["-x", "-k", directory.appendingPathComponent("upload.zip").path, unpacked.path])
                guard let app = Self.findApp(in: unpacked) else { throw UploadError("no .app in \(name)") }
                guard let bundleID = Bundle(url: app)?.bundleIdentifier else { throw UploadError("\(app.lastPathComponent) has no bundle identifier") }
                try Self.run("/usr/bin/xcrun", ["simctl", "install", udid, app.path])
                try Self.run("/usr/bin/xcrun", ["simctl", "launch", udid, bundleID])
                print("installed and launched \(bundleID)")
                report(InstallStatus(state: .launched, message: bundleID))
            } catch {
                print("install \(name): \(error)")
                report(InstallStatus(state: .failed, message: "\(error)"))
            }
        }
    }

    /// The `.app` at the top of the archive, or one level down (zips of a folder, `Payload/` of an .ipa).
    private static func findApp(in directory: URL) -> URL? {
        let fm = FileManager.default
        var level = [directory]
        for _ in 0..<3 {
            var next: [URL] = []
            for dir in level {
                let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
                if let app = items.first(where: { $0.pathExtension == "app" }) { return app }
                next += items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && $0.lastPathComponent != "__MACOSX" }
            }
            level = next
        }
        return nil
    }

    private static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UploadError("\((arguments.first == "simctl" ? "simctl \(arguments[1])" : URL(fileURLWithPath: tool).lastPathComponent)): \(text.split(separator: "\n").last.map(String.init) ?? "exit \(process.terminationStatus)")")
        }
    }
}

struct UploadError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
