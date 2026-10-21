import Foundation
import MaccheriProtocol
import Testing
@testable import GuestCore

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "maccheri-guest-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func readsSessionJSON() throws {
    let share = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: share) }
    #expect(SessionSource.read(share: share) == nil)

    let session = GuestSession.simulator(GuestSimulatorSession(sessionID: UUID(), device: .iPhone17Pro))
    try JSONEncoder().encode(session).write(to: share.appending(path: GuestAPI.sessionFile))
    #expect(SessionSource.read(share: share) == session)
}

@Test func halfWrittenSessionIsRetried() throws {
    let share = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: share) }
    try Data(#"{"ci":{"_0":{"jitCon"#.utf8).write(to: share.appending(path: GuestAPI.sessionFile))
    #expect(SessionSource.read(share: share) == nil)
}

@Test func acceptsLegacyJITConfig() throws {
    let share = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: share) }
    try Data("abc123\n".utf8).write(to: share.appending(path: SessionSource.legacyJITConfigFile))
    #expect(SessionSource.read(share: share) == .ci(GuestCIJob(jitConfig: "abc123")))
}

@Test func waitsForSessionToAppear() async throws {
    let share = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: share) }
    let waiter = Task { try await SessionSource.wait(share: share, every: .milliseconds(20)) }
    try await Task.sleep(for: .milliseconds(100))
    try JSONEncoder().encode(GuestSession.ci(GuestCIJob(jitConfig: "x"))).write(to: share.appending(path: GuestAPI.sessionFile))
    #expect(try await waiter.value == .ci(GuestCIJob(jitConfig: "x")))
}

@Test func picksBootedDeviceOfTheRightTypeAndRuntime() throws {
    let json = #"""
    {"devices":{
      "com.apple.CoreSimulator.SimRuntime.iOS-27-2":[
        {"udid":"A","name":"iPhone 18 Pro","state":"Shutdown","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro"},
        {"udid":"B","name":"iPhone 17 Pro","state":"Shutdown","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"},
        {"udid":"C","name":"iPhone 17 Pro","state":"Booted","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"},
        {"udid":"D","name":"iPhone 17 Pro","state":"Booted","isAvailable":false,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"}
      ],
      "com.apple.CoreSimulator.SimRuntime.iOS-26-0":[
        {"udid":"E","name":"iPhone 17 Pro","state":"Booted","isAvailable":true,"deviceTypeIdentifier":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro"}
      ]
    }}
    """#
    let list = try JSONDecoder().decode(SimulatorList.self, from: Data(json.utf8))
    #expect(list.device(matching: .iPhone17Pro)?.udid == "C")
    #expect(list.device(matching: DeviceSpec(deviceType: "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro", runtime: DeviceSpec.iPhone17Pro.runtime))?.udid == "A")
    #expect(list.device(matching: DeviceSpec(deviceType: "com.apple.CoreSimulator.SimDeviceType.iPad-Pro", runtime: DeviceSpec.iPhone17Pro.runtime)) == nil)
}

@Test func imageMetadataRoundTrips() throws {
    let json = #"{"labels":["maccheri","macos-27"],"devices":[{"deviceType":"com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro","runtime":"com.apple.CoreSimulator.SimRuntime.iOS-27-2"}],"guestVersion":"1"}"#
    let metadata = try JSONDecoder().decode(ImageMetadata.self, from: Data(json.utf8))
    #expect(metadata == ImageMetadata(labels: ["maccheri", "macos-27"], devices: [.iPhone17Pro], guestVersion: "1"))
}

@Test func subprocessCapturesOutputAndFailures() async throws {
    #expect(try await Subprocess.run("/bin/echo", ["hi"]) == "hi\n")
    await #expect(throws: Subprocess.Failure.self) {
        try await Subprocess.run("/bin/sh", ["-c", "echo oops; exit 3"])
    }
}

@Test func cancellingWaitTerminatesTheChild() async throws {
    let child = try Subprocess("/bin/sleep", ["30"])
    let waiter = Task { await child.wait() }
    try await Task.sleep(for: .milliseconds(100))
    waiter.cancel()
    #expect(await waiter.value == SIGTERM)
    #expect(!child.isRunning)
}

@Test func detectsListener() async throws {
    #expect(!GuestDaemon.canConnect(port: 1))
}
