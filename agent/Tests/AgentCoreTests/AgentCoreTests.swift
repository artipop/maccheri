import Foundation
import MaccheriProtocol
import Testing
@testable import AgentCore

/// Makes a fake Tart-style bundle; the "disk" is a few bytes, which is all clonefile needs.
func makeImage(in directory: URL, name: String) throws -> URL {
    let url = directory.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let config = VMBundle.Config(cpuCount: 4, memorySize: 8 << 30, hardwareModel: Data("model".utf8).base64EncodedString())
    try JSONEncoder().encode(config).write(to: url.appending(path: "config.json"))
    try Data("disk".utf8).write(to: url.appending(path: "disk.img"))
    try Data("nvram".utf8).write(to: url.appending(path: "nvram.bin"))
    return url
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "maccheri-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func readsTartConfigIgnoringUnknownKeys() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let json = #"{"version":1,"os":"darwin","arch":"arm64","cpuCountMin":4,"cpuCount":4,"memorySizeMin":4294967296,"memorySize":8589934592,"macAddress":"aa:bb:cc:dd:ee:ff","display":{"width":1024,"height":768},"hardwareModel":"bW9kZWw=","ecid":"AAAA"}"#
    try Data(json.utf8).write(to: dir.appending(path: "config.json"))
    let bundle = try VMBundle(url: dir)
    #expect(bundle.config.cpuCount == 4)
    #expect(bundle.config.memorySize == 8 << 30)
    #expect(bundle.hardwareModelData == Data("model".utf8))
}

@Test func rejectsLinuxImages() throws {
    let dir = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    try Data(#"{"os":"linux","arch":"arm64","cpuCount":2,"memorySize":1}"#.utf8).write(to: dir.appending(path: "config.json"))
    #expect(throws: AgentError.self) { try VMBundle(url: dir) }
}

@Test func cloneIsIndependentAndDestroyed() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let images = root.appending(path: "images")
    _ = try makeImage(in: images, name: "base")
    let store = ImageStore(imagesDirectory: images, workDirectory: root.appending(path: "work"))

    let clone = try store.clone(try store.baseImage(named: "base"), jobID: UUID())
    try Data("dirty".utf8).write(to: clone.diskURL)
    #expect(try Data(contentsOf: images.appending(path: "base/disk.img")) == Data("disk".utf8))

    store.destroy(clone)
    #expect(!FileManager.default.fileExists(atPath: clone.url.path))
    #expect(FileManager.default.fileExists(atPath: images.appending(path: "base").path))
}

@Test(arguments: ["", "../etc", ".hidden", "a/b"])
func refusesImageNamesOutsideStore(name: String) throws {
    let store = ImageStore(imagesDirectory: URL(filePath: "/nonexistent"), workDirectory: URL(filePath: "/nonexistent-work"))
    #expect(throws: AgentError.self) { try store.baseImage(named: name) }
}

actor FakeSource: JobSource {
    var pending: [JobLease]
    var completed: [(UUID, CompleteRequest)] = []
    init(_ leases: [JobLease]) { pending = leases }

    func lease(_ request: LeaseRequest) async throws -> JobLease? {
        pending.isEmpty ? nil : pending.removeFirst()
    }
    func complete(jobID: UUID, _ request: CompleteRequest) async throws {
        completed.append((jobID, request))
    }
}

final class FakeVM: VMRunner, @unchecked Sendable {
    let exit: VMExit
    private(set) var sawJitConfig: String?
    private(set) var ranFrom: URL?
    init(exit: VMExit) { self.exit = exit }

    func run(_ bundle: VMBundle, sharedDirectory: URL, timeout: Duration) async throws -> VMExit {
        sawJitConfig = try String(contentsOf: sharedDirectory.appending(path: "jitconfig"), encoding: .utf8)
        ranFrom = bundle.url
        return exit
    }
}

@Test(arguments: [(VMExit.guestStopped, JobOutcome.finished), (.timedOut, .timedOut)])
func runsLeaseInDisposableClone(exit: VMExit, expected: JobOutcome) async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let images = root.appending(path: "images")
    _ = try makeImage(in: images, name: "macos")
    let lease = JobLease(jobID: UUID(), githubJobID: 1, repository: "o/r", image: "macos", jitConfig: "JIT", timeoutSeconds: 60)
    let source = FakeSource([lease])
    let vm = FakeVM(exit: exit)
    let runner = JobRunner(
        source: source,
        images: ImageStore(imagesDirectory: images, workDirectory: root.appending(path: "work")),
        vm: vm, labels: ["maccheri"], log: { _ in }
    )

    #expect(try await runner.runOnce())
    #expect(vm.sawJitConfig == "JIT")
    #expect(vm.ranFrom?.deletingLastPathComponent().lastPathComponent == "work")
    #expect(!FileManager.default.fileExists(atPath: vm.ranFrom!.path), "clone must be gone after the job")
    let completed = await source.completed
    #expect(completed.map(\.0) == [lease.jobID])
    #expect(completed.first?.1.outcome == expected)

    #expect(try await !runner.runOnce())
}

@Test func missingImageIsReportedAsFailure() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let lease = JobLease(jobID: UUID(), githubJobID: 2, repository: "o/r", image: "nope", jitConfig: "JIT", timeoutSeconds: 60)
    let source = FakeSource([lease])
    let runner = JobRunner(
        source: source,
        images: ImageStore(imagesDirectory: root, workDirectory: root.appending(path: "work")),
        vm: FakeVM(exit: .guestStopped), labels: [], log: { _ in }
    )
    #expect(try await runner.runOnce())
    let completed = await source.completed
    #expect(completed.first?.1.outcome == .vmFailed)
}
