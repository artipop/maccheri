import Foundation
import MaccheriProtocol
import NIOConcurrencyHelpers
import XCTVapor
@testable import ControlPlane

/// Time the test moves by hand.
final class TestClock: Sendable {
    private let date = NIOLockedValueBox(Date(timeIntervalSince1970: 1_792_576_800))

    var now: Date { date.withLockedValue { $0 } }
    func advance(seconds: TimeInterval) { date.withLockedValue { $0.addTimeInterval(seconds) } }
    var appClock: AppClock { AppClock { self.now } }
}

/// One app per test on a fresh SQLite file, no background sweep, 1 s long-poll.
class ControlPlaneTestCase: XCTestCase {
    let webhookSecret = "s3cret"
    let turnSecret = "fixture-turn-secret"
    var app: Application!
    let clock = TestClock()
    let provisioner = FakeProvisioner()
    private var databaseDirectory: URL!

    func makeSettings() -> Settings {
        var settings = Settings(
            publicURL: URL(string: "https://maccheri.example")!,
            databasePath: databaseDirectory.appendingPathComponent("test.sqlite").path,
            publicDirectory: nil,
            adminInvite: nil
        )
        settings.longPollSeconds = 1
        settings.sweepSeconds = nil
        settings.turn = TURNSettings(host: "turn.maccheri.example", secret: turnSecret, port: 3478, tlsPort: 443)
        settings.webhookSecret = webhookSecret
        settings.defaultImage = "test-image"
        settings.jobTimeoutSeconds = 600
        return settings
    }

    override func setUp() async throws {
        databaseDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("controlplane-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)
        app = try await Application.make(.testing)
        try await configure(app, settings: makeSettings(), provisioner: provisioner, clock: clock.appClock)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
        try? FileManager.default.removeItem(at: databaseDirectory)
    }

    /// Restarts on the same database with changed settings.
    func restart(_ change: (inout Settings) -> Void = { _ in }) async throws {
        try await app.asyncShutdown()
        app = try await Application.make(.testing)
        var settings = makeSettings()
        change(&settings)
        try await configure(app, settings: settings, provisioner: provisioner, clock: clock.appClock)
    }

    // MARK: - Users

    /// Redeems a fresh invite; the first user is an admin.
    func signUp(_ name: String, admin: Bool = true) async throws -> UserToken {
        let invite = try await AuthController.createInvite(isAdmin: admin, createdBy: nil, on: app.db, maccheri: app.maccheri)
        return try await post("v1/auth/redeem", RedeemInviteRequest(code: invite.code, name: name), as: UserToken.self)
    }

    // MARK: - Hosts

    static let hardware = HostHardware(model: "Mac16,10", chip: "Apple M4", cpuCount: 10, memoryBytes: 16 << 30, macOSVersion: "27.0.1")

    static func capacity(freeSlots: Int = 1, warmVMs: Int = 0, devices: [DeviceSpec] = [.iPhone17Pro], labels: [String] = ["maccheri"]) -> HostCapacity {
        HostCapacity(freeSlots: freeSlots, warmVMs: warmVMs, images: ["test-image"], labels: labels, devices: devices)
    }

    /// Enrolls a host and sends its first heartbeat.
    func enrollHost(_ name: String, owner: UserToken, capacity: HostCapacity = ControlPlaneTestCase.capacity()) async throws -> HostEnrollment {
        let enrollment = try await post("v1/hosts/enroll", HostEnrollRequest(name: name, hardware: Self.hardware), as: HostEnrollment.self, token: owner.token)
        _ = try await heartbeat(enrollment, capacity: capacity)
        return enrollment
    }

    func heartbeat(_ host: HostEnrollment, capacity: HostCapacity = ControlPlaneTestCase.capacity()) async throws -> HeartbeatResponse {
        try await post("agent/v1/heartbeat", Heartbeat(agentVersion: "test", capacity: capacity), as: HeartbeatResponse.self, token: host.agentToken)
    }

    /// `POST /agent/v1/work`; nil on 204.
    func work(_ host: HostEnrollment, freeSlots: Int = 1, labels: [String] = ["maccheri"]) async throws -> WorkLease? {
        var lease: WorkLease?
        try await app.test(.POST, "agent/v1/work", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: host.agentToken)
            try req.content.encode(LeaseRequest(labels: labels, freeSlots: freeSlots))
        }) { res async throws in
            if res.status == .ok { lease = try res.content.decode(WorkLease.self) }
            else { XCTAssertEqual(res.status, .noContent, res.body.string) }
        }
        return lease
    }

    func report(_ host: HostEnrollment, session: UUID, _ state: HostSessionState, message: String? = nil) async throws -> HTTPStatus {
        try await status(.POST, "agent/v1/sessions/\(session.uuidString)/state", SessionStateReport(state: state, message: message), token: host.agentToken)
    }

    // MARK: - Sessions

    func createSession(_ user: UserToken, _ request: CreateSessionRequest = CreateSessionRequest()) async throws -> SessionInfo {
        try await post("v1/sessions", request, as: SessionInfo.self, token: user.token)
    }

    func session(_ id: UUID, user: UserToken) async throws -> SessionInfo {
        var info: SessionInfo!
        try await app.test(.GET, "v1/sessions/\(id.uuidString)", headers: ["Authorization": "Bearer \(user.token)"]) { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
            info = try res.content.decode(SessionInfo.self)
        }
        return info
    }

    func sweep() async throws {
        try await Lifecycle.sweep(on: app.db, maccheri: app.maccheri, logger: app.logger)
    }

    // MARK: - HTTP

    func post<Body: Content, Reply: Decodable>(_ path: String, _ body: Body, as: Reply.Type, token: String? = nil, file: StaticString = #filePath, line: UInt = #line) async throws -> Reply {
        var reply: Reply!
        try await app.test(.POST, path, beforeRequest: { req async throws in
            if let token { req.headers.bearerAuthorization = .init(token: token) }
            try req.content.encode(body)
        }) { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string, file: file, line: line)
            reply = try res.content.decode(Reply.self)
        }
        return reply
    }

    func status<Body: Content>(_ method: HTTPMethod, _ path: String, _ body: Body?, token: String?) async throws -> HTTPStatus {
        var status: HTTPStatus = .internalServerError
        try await app.test(method, path, beforeRequest: { req async throws in
            if let token { req.headers.bearerAuthorization = .init(token: token) }
            if let body { try req.content.encode(body) }
        }) { res async throws in
            status = res.status
        }
        return status
    }

    func status(_ method: HTTPMethod, _ path: String, token: String?) async throws -> HTTPStatus {
        try await status(method, path, Optional<Empty>.none, token: token)
    }
}

struct Empty: Content {}

actor FakeProvisioner: RunnerProvisioner {
    struct Call: Equatable { var repository: String; var labels: [String] }
    private(set) var calls: [Call] = []
    private var shouldFail = false

    func failNext() { shouldFail = true }

    func jitConfig(installationID: Int64, repository: String, runnerName: String, labels: [String]) async throws -> String {
        if shouldFail {
            shouldFail = false
            throw Abort(.internalServerError)
        }
        calls.append(Call(repository: repository, labels: labels))
        return "jit-for-\(repository)"
    }
}

extension WorkLease {
    var simulator: SimulatorSessionLease? {
        if case .simulator(let lease) = self { lease } else { nil }
    }
    var ci: JobLease? {
        if case .ci(let lease) = self { lease } else { nil }
    }
}

// XCTAssert's autoclosures can't await.
func assertEqual<T: Equatable>(_ actual: @autoclosure () async throws -> T, _ expected: @autoclosure () -> T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
    let value = try await actual()
    XCTAssertEqual(value, expected(), message, file: file, line: line)
}

func assertNil<T>(_ actual: @autoclosure () async throws -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) async throws {
    let value = try await actual()
    XCTAssertNil(value, message, file: file, line: line)
}

func unwrap<T>(_ actual: @autoclosure () async throws -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
    let value = try await actual()
    return try XCTUnwrap(value, file: file, line: line)
}
