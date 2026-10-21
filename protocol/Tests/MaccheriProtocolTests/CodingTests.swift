import Foundation
import Testing
@testable import MaccheriProtocol

@Test func leaseRoundTrip() throws {
    let lease = JobLease(
        jobID: UUID(), githubJobID: 42, repository: "octo/repo",
        image: "macos-27-xcode", jitConfig: "abc==", timeoutSeconds: 3600
    )
    let data = try JSONEncoder().encode(lease)
    #expect(try JSONDecoder().decode(JobLease.self, from: data) == lease)
}

@Test func outcomeWireFormat() throws {
    let data = try JSONEncoder().encode(CompleteRequest(outcome: .timedOut, durationSeconds: 1))
    #expect(String(decoding: data, as: UTF8.self).contains("\"timedOut\""))
}

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(T.self, from: encoder.encode(value))
}

private let signaling = SignalingInfo(
    url: URL(string: "wss://cp.example.com/v1/sessions/x/signal")!,
    token: "t",
    iceServers: [ICEServer(urls: ["turn:turn.example.com:3478"], username: "1:x", credential: "c")]
)

@Test func workLeaseRoundTrip() throws {
    let ci = WorkLease.ci(JobLease(jobID: UUID(), githubJobID: 1, repository: "o/r", image: "i", jitConfig: "j", timeoutSeconds: 60))
    let sim = WorkLease.simulator(SimulatorSessionLease(sessionID: UUID(), image: "i", device: .iPhone17Pro, timeoutSeconds: 60, signaling: signaling))
    #expect(try roundTrip(ci) == ci)
    #expect(try roundTrip(sim) == sim)
}

@Test func signalMessagesRoundTrip() throws {
    for message: SignalMessage in [.offer(sdp: "v=0"), .answer(sdp: "v=0"), .candidate(candidate: "candidate:1", sdpMid: "0", sdpMLineIndex: 0), .bye(reason: nil)] {
        #expect(try roundTrip(message) == message)
    }
}

@Test func sessionAndHostRoundTrip() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let session = SessionInfo(id: UUID(), state: .ready, device: .iPhone17Pro, hostID: UUID(), hostName: "mini", createdAt: now, expiresAt: now, signaling: signaling, message: nil)
    #expect(try roundTrip(session) == session)
    let hardware = HostHardware(model: "Mac16,10", chip: "Apple M4", cpuCount: 10, memoryBytes: 16 << 30, macOSVersion: "27.0.1")
    let capacity = HostCapacity(freeSlots: 1, warmVMs: 1, images: ["macos-27-xcode-27.2"], labels: ["maccheri"], devices: [.iPhone17Pro])
    let host = HostInfo(id: UUID(), name: "mini", ownerName: "artem", hardware: hardware, online: true, capacity: capacity)
    #expect(try roundTrip(host) == host)
    #expect(try roundTrip(Heartbeat(agentVersion: "0.1", capacity: capacity)).capacity == capacity)
}

@Test func guestSessionRoundTrip() throws {
    let sim = GuestSession.simulator(GuestSimulatorSession(sessionID: UUID(), device: .iPhone17Pro))
    #expect(try roundTrip(sim) == sim)
    #expect(try roundTrip(GuestSession.ci(GuestCIJob(jitConfig: "abc"))) == .ci(GuestCIJob(jitConfig: "abc")))
}

@Test func heartbeatResponseRoundTrip() throws {
    let response = HeartbeatResponse(endedSessions: [UUID()])
    #expect(try roundTrip(response) == response)
}

@Test func imageMetadataWireFormat() throws {
    let json = #"{"labels":["maccheri"],"devices":[{"deviceType":"t","runtime":"r"}],"guestVersion":"1"}"#
    let metadata = try JSONDecoder().decode(ImageMetadata.self, from: Data(json.utf8))
    #expect(metadata == ImageMetadata(labels: ["maccheri"], devices: [DeviceSpec(deviceType: "t", runtime: "r")], guestVersion: "1"))
}

@Test func teamsV2RoundTrip() throws {
    let team = Team(id: UUID(), name: "maccheri", role: .owner)
    #expect(try roundTrip(team) == team)
    let me = UserInfo(id: UUID(), name: "Artem", isAdmin: false, login: "artem", avatarURL: URL(string: "https://avatars.githubusercontent.com/u/1"), teams: [team])
    #expect(try roundTrip(me) == me)
    let invite = Invite(code: "c", expiresAt: Date(timeIntervalSince1970: 1_800_000_000), teamID: team.id, role: .member, url: URL(string: "https://x/invite/c"))
    #expect(try roundTrip(invite) == invite)
    #expect(try roundTrip(HostEnrollRequest(name: "mini", hardware: HostHardware(model: "m", chip: "c", cpuCount: 1, memoryBytes: 1, macOSVersion: "27"), code: "hc_1")).code == "hc_1")
    #expect(TeamRole.member < .admin && .admin < .owner)
}

@Test func v1ShapesUnchanged() throws {
    // v2 fields are optional and omitted when nil, so v1 JSON stays byte-for-byte the same.
    let json = String(decoding: try JSONEncoder().encode(UserInfo(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, name: "A", isAdmin: true)), as: UTF8.self)
    #expect(!json.contains("login") && !json.contains("teams"))
}
