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

    /// Deletes every clone left in the work directory, e.g. by an agent that crashed or was killed
    /// mid-job. Only call this while holding ``WorkDirectoryLock``. Returns the removed names.
    @discardableResult
    public func removeOrphans() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: workDirectory.path)) ?? []
        let orphans = names.filter { UUID(uuidString: $0) != nil }
        for name in orphans {
            try? FileManager.default.removeItem(at: workDirectory.appending(path: name, directoryHint: .isDirectory))
        }
        return orphans
    }
}

/// One agent per work directory: an exclusive `flock` on `<work>/.lock`, held for the process's
/// lifetime (the kernel drops it if the process dies), so the app and the CLI can't delete each
/// other's clones.
public final class WorkDirectoryLock: Sendable {
    private let fd: Int32

    public init(workDirectory: URL) throws {
        try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let path = workDirectory.appending(path: ".lock").path
        fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw AgentError.workDirectoryBusy(path) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw AgentError.workDirectoryBusy(path)
        }
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

