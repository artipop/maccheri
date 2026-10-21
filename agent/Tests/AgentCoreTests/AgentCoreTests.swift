import Foundation
import MaccheriProtocol
import Network
import Testing
@testable import AgentCore

/// Makes a fake Tart-style bundle; the "disk" is a few bytes, which is all clonefile needs.
func makeImage(in directory: URL, name: String, memory: UInt64 = 8 << 30, metadata: ImageMetadata? = nil) throws -> URL {
    let url = directory.appending(path: name, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    if let metadata { try JSONEncoder().encode(metadata).write(to: url.appending(path: ImageMetadata.fileName)) }
    let config = VMBundle.Config(cpuCount: 4, memorySize: memory, hardwareModel: Data("model".utf8).base64EncodedString())
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

@Test(arguments: [("7300:7301", TCPForwarder.Mapping(hostPort: 7300, guestPort: 7301)), ("7300", .init(hostPort: 7300, guestPort: 7300))])
func parsesForwardSpec(spec: String, expected: TCPForwarder.Mapping) {
    #expect(TCPForwarder.Mapping(spec) == expected)
}

@Test(arguments: ["", ":", "0:1", "1:0", "a:1", "1:2:3", "70000:1"])
func rejectsBadForwardSpec(spec: String) {
    #expect(TCPForwarder.Mapping(spec) == nil)
}

/// Echo server on loopback, forwarder in front of it, client through the forwarder.
@Test func forwardsBothWays() async throws {
    let queue = DispatchQueue(label: "echo")
    let echo = try NWListener(using: .tcp, on: .any)
    echo.newConnectionHandler = { connection in
        connection.start(queue: queue)
        func loop() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, _ in
                if let data { connection.send(content: data, completion: .contentProcessed { _ in }) }
                if done { connection.cancel() } else { loop() }
            }
        }
        loop()
    }
    try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
        echo.stateUpdateHandler = { state in
            if case .ready = state { c.resume() }
            if case .failed(let e) = state { c.resume(throwing: e) }
        }
        echo.start(queue: queue)
    }
    defer { echo.cancel() }

    let forwarder = try TCPForwarder(.init(hostPort: 0, guestPort: echo.port!.rawValue), guestHost: "127.0.0.1")
    try await forwarder.start()
    defer { forwarder.stop() }

    let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: forwarder.port!)!, using: .tcp)
    client.start(queue: queue)
    defer { client.cancel() }
    let payload = Data((0..<300_000).map { UInt8($0 % 251) })
    client.send(content: payload, completion: .contentProcessed { _ in })
    var received = Data()
    while received.count < payload.count {
        let chunk: Data = try await withCheckedThrowingContinuation { c in
            client.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, _, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: data ?? Data()) }
            }
        }
        received.append(chunk)
    }
    #expect(received == payload)
}
