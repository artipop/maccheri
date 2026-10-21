import Foundation
import MaccheriProtocol

// Fixed values so the files only change when the contract does.
let userID = UUID(uuidString: "6F1C2A4E-8B1D-4C0E-9A57-3D2E1F0A9B11")!
let hostID = UUID(uuidString: "0B7E5C3A-2D4F-4A61-8E9B-7C1D2E3F4A52")!
let sessionID = UUID(uuidString: "C4A1E8D2-5B3F-4E7A-9C0D-1E2F3A4B5C63")!
let jobID = UUID(uuidString: "9D8C7B6A-5F4E-4D3C-8B2A-1F0E9D8C7B74")!
let createdAt = Date(timeIntervalSince1970: 1_792_576_800) // 2026-10-21T10:00:00Z
let expiresAt = createdAt.addingTimeInterval(3600)

let iceServers = [
    ICEServer(urls: ["stun:turn.maccheri.example:3478"]),
    ICEServer(
        urls: [
            "turn:turn.maccheri.example:3478?transport=udp",
            "turn:turn.maccheri.example:3478?transport=tcp",
            "turns:turn.maccheri.example:443?transport=tcp",
        ],
        // TURN REST API with `static-auth-secret=fixture-turn-secret`: the username is
        // `<session expiresAt as Unix time>:<session id>`, the credential base64(HMAC-SHA1(secret, username)).
        // A real test vector: the server's tests recompute it.
        username: "1792580400:\(sessionID.uuidString)",
        credential: "ZZ224NG03WwZNUC7kHDwTZ2AqA0="
    ),
]

func signaling(_ role: SignalingRole, token: String) -> SignalingInfo {
    SignalingInfo(
        url: URL(string: "wss://maccheri.example\(SignalingAPI.signalPath(sessionID: sessionID))?role=\(role.rawValue)&token=\(token)")!,
        token: token,
        iceServers: iceServers
    )
}

let viewerSignaling = signaling(.viewer, token: "mcs_viewer_3kV9pQ2xL7nR4tY8wZ1b")
let hostSignaling = signaling(.host, token: "mcs_host_8cJ5mN2vB6xK9qW3eR7t")

let hardware = HostHardware(model: "Mac16,10", chip: "Apple M4", cpuCount: 10, memoryBytes: 17_179_869_184, macOSVersion: "27.0.1")
let capacity = HostCapacity(
    freeSlots: 0,
    warmVMs: 1,
    images: ["macos-27-xcode-27.2"],
    labels: ["maccheri", "macos-27", "xcode-27.2"],
    devices: [.iPhone17Pro]
)

func session(_ state: SessionState, message: String? = nil) -> SessionInfo {
    let assigned = state != .queued
    return SessionInfo(
        id: sessionID,
        state: state,
        device: assigned ? .iPhone17Pro : nil,
        hostID: assigned ? hostID : nil,
        hostName: assigned ? "Artem's Mac mini" : nil,
        createdAt: createdAt,
        expiresAt: expiresAt,
        signaling: state == .starting || state == .ready ? viewerSignaling : nil,
        message: message
    )
}

let jobLease = JobLease(
    jobID: jobID,
    githubJobID: 41_234_567_890,
    repository: "octo/repo",
    image: "macos-27-xcode-27.2",
    jitConfig: "eyJydW5uZXIiOiJleGFtcGxlIn0=",
    timeoutSeconds: 3600
)

// File name → value. Requests and responses of every API in MaccheriProtocol the server speaks.
let fixtures: [(String, any Encodable)] = [
    // Auth
    ("invite", Invite(code: "mci_Zx8Lq2Vn5Rt9Kp3W", expiresAt: createdAt.addingTimeInterval(7 * 86_400))),
    ("redeem-invite-request", RedeemInviteRequest(code: "mci_Zx8Lq2Vn5Rt9Kp3W", name: "Artem")),
    ("user-token", UserToken(userID: userID, token: "mcu_N4bV7cX2zL9kJ5hG3fD8sA1qW6eR0tY")),
    ("user-info", UserInfo(id: userID, name: "Artem", isAdmin: true)),
    // Hosts
    ("host-enroll-request", HostEnrollRequest(name: "Artem's Mac mini", hardware: hardware)),
    ("host-enrollment", HostEnrollment(hostID: hostID, agentToken: "mca_P5oI8uY3tR6eW9qA2sD4fG7hJ1kL0zX")),
    ("heartbeat", Heartbeat(agentVersion: "0.1.0", capacity: capacity)),
    ("heartbeat-response", HeartbeatResponse(endedSessions: [sessionID])),
    ("heartbeat-response-empty", HeartbeatResponse()),
    ("hosts", [
        HostInfo(id: hostID, name: "Artem's Mac mini", ownerName: "Artem", hardware: hardware, online: true, capacity: capacity),
        HostInfo(id: UUID(uuidString: "1A2B3C4D-5E6F-4A7B-8C9D-0E1F2A3B4C85")!, name: "Studio", ownerName: "Artem", hardware: hardware, online: false, capacity: nil),
    ]),
    // Sessions
    ("create-session-request", CreateSessionRequest(device: .iPhone17Pro)),
    ("create-session-request-any", CreateSessionRequest()),
    ("session-queued", session(.queued)),
    ("session-starting", session(.starting)),
    ("session-ready", session(.ready)),
    ("session-ended", session(.ended, message: "ended by user")),
    ("session-failed", session(.failed, message: "host went offline")),
    // Signaling: one WebSocket text frame each
    ("signal-offer", SignalMessage.offer(sdp: "v=0\r\no=- 4611731400430051336 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n")),
    ("signal-answer", SignalMessage.answer(sdp: "v=0\r\no=- 1234567890 2 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n")),
    ("signal-candidate", SignalMessage.candidate(
        candidate: "candidate:842163049 1 udp 1677729535 203.0.113.7 54321 typ srflx raddr 0.0.0.0 rport 0 generation 0",
        sdpMid: "0",
        sdpMLineIndex: 0
    )),
    ("signal-candidate-end", SignalMessage.candidate(candidate: "", sdpMid: nil, sdpMLineIndex: nil)),
    ("signal-bye", SignalMessage.bye(reason: "session ended")),
    ("signal-bye-empty", SignalMessage.bye(reason: nil)),
    // Work (agent)
    ("lease-request", LeaseRequest(labels: ["maccheri", "macos-27", "xcode-27.2"], freeSlots: 1)),
    ("work-lease-ci", WorkLease.ci(jobLease)),
    ("work-lease-simulator", WorkLease.simulator(SimulatorSessionLease(
        sessionID: sessionID,
        image: "macos-27-xcode-27.2",
        device: .iPhone17Pro,
        timeoutSeconds: 3600,
        signaling: hostSignaling
    ))),
    ("session-state-report", SessionStateReport(state: .ready)),
    ("session-state-report-failed", SessionStateReport(state: .failed, message: "simstream did not start in 120 s")),
    ("complete-request", CompleteRequest(outcome: .finished, durationSeconds: 512.5)),
    // Legacy CI-only lease (`/agent/v1/lease`)
    ("job-lease", jobLease),
]

let output = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() // Tools/fixtures
    .deletingLastPathComponent().deletingLastPathComponent() // controlplane
    .appendingPathComponent("Tests/Fixtures", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]

for (name, value) in fixtures {
    var data = try encoder.encode(value)
    data.append(0x0A)
    try data.write(to: output.appendingPathComponent("\(name).json"))
}
print("wrote \(fixtures.count) fixtures to \(output.path)")
