import Darwin
import Foundation

/// Base images live in `imagesDirectory/<name>`; every job gets a copy-on-write clone in
/// `workDirectory/<job id>` that is deleted when the job ends, so nothing survives between jobs.
public struct ImageStore: Sendable {
    public let imagesDirectory: URL
    public let workDirectory: URL

    public init(imagesDirectory: URL, workDirectory: URL) {
        self.imagesDirectory = imagesDirectory
        self.workDirectory = workDirectory
    }

    public func baseImage(named name: String) throws -> VMBundle {
        // Image names come from the control plane; never let them escape the images directory.
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else {
            throw AgentError.imageNotFound(name)
        }
        let url = imagesDirectory.appending(path: name, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AgentError.imageNotFound(name)
        }
        return try VMBundle(url: url)
    }

    /// APFS `clonefile(2)` copies the whole bundle in O(1) and shares blocks with the base
    /// image until the guest writes to them. Both directories must be on the same APFS volume.
    public func clone(_ base: VMBundle, jobID: UUID) throws -> VMBundle {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let destination = workDirectory.appending(path: jobID.uuidString, directoryHint: .isDirectory)
        if clonefile(base.url.path, destination.path, UInt32(CLONE_NOFOLLOW)) != 0 {
            throw AgentError.cloneFailed(path: destination.path, errno: errno)
        }
        return try VMBundle(url: destination)
    }

    public func destroy(_ clone: VMBundle) {
        // Only ever delete what we created under the work directory.
        guard clone.url.standardizedFileURL.path.hasPrefix(workDirectory.standardizedFileURL.path + "/") else { return }
        try? FileManager.default.removeItem(at: clone.url)
    }
}
