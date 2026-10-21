import Foundation
import MaccheriProtocol
import XCTVapor
@testable import ControlPlane

/// `Tests/Fixtures/*.json` are what the web client (and any rewrite of this server) checks against.
/// Each one must decode into its contract type and encode back to exactly the same JSON with the
/// server's encoder.
final class FixtureTests: ControlPlaneTestCase {
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    func testFixturesRoundTripThroughTheServerEncoder() throws {
        let checks: [String: (Data) throws -> Data] = [
            "invite": roundTrip(Invite.self),
            "redeem-invite-request": roundTrip(RedeemInviteRequest.self),
            "user-token": roundTrip(UserToken.self),
            "user-info": roundTrip(UserInfo.self),
            "host-enroll-request": roundTrip(HostEnrollRequest.self),
            "host-enrollment": roundTrip(HostEnrollment.self),
            "heartbeat": roundTrip(Heartbeat.self),
            "heartbeat-response": roundTrip(HeartbeatResponse.self),
            "heartbeat-response-empty": roundTrip(HeartbeatResponse.self),
            "hosts": roundTrip([HostInfo].self),
            "create-session-request": roundTrip(CreateSessionRequest.self),
            "create-session-request-any": roundTrip(CreateSessionRequest.self),
            "session-queued": roundTrip(SessionInfo.self),
            "session-starting": roundTrip(SessionInfo.self),
            "session-ready": roundTrip(SessionInfo.self),
            "session-ended": roundTrip(SessionInfo.self),
            "session-failed": roundTrip(SessionInfo.self),
            "signal-offer": roundTrip(SignalMessage.self),
            "signal-answer": roundTrip(SignalMessage.self),
            "signal-candidate": roundTrip(SignalMessage.self),
            "signal-candidate-end": roundTrip(SignalMessage.self),
            "signal-bye": roundTrip(SignalMessage.self),
            "signal-bye-empty": roundTrip(SignalMessage.self),
            "lease-request": roundTrip(LeaseRequest.self),
            "work-lease-ci": roundTrip(WorkLease.self),
            "work-lease-simulator": roundTrip(WorkLease.self),
            "session-state-report": roundTrip(SessionStateReport.self),
            "session-state-report-failed": roundTrip(SessionStateReport.self),
            "complete-request": roundTrip(CompleteRequest.self),
            "job-lease": roundTrip(JobLease.self),
        ]

        let files = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path)
            .filter { $0.hasSuffix(".json") }
            .map { String($0.dropLast(5)) }
        XCTAssertEqual(Set(files), Set(checks.keys), "every fixture is checked, every check has a fixture")

        for (name, check) in checks.sorted(by: { $0.key < $1.key }) {
            let fixture = try Data(contentsOf: Self.directory.appendingPathComponent("\(name).json"))
            let encoded = try check(fixture)
            XCTAssertEqual(try json(encoded), try json(fixture), name)
        }
    }

    /// The TURN credential in the fixtures is a real test vector for `fixture-turn-secret`.
    func testTURNCredentialMatchesFixture() throws {
        let fixture = try Data(contentsOf: Self.directory.appendingPathComponent("session-ready.json"))
        let info = try JSONDecoder.custom(dates: .iso8601).decode(SessionInfo.self, from: fixture)
        let turn = try XCTUnwrap(info.signaling?.iceServers.first { $0.username != nil })
        XCTAssertEqual(ICEServers.credential(username: turn.username!, secret: turnSecret), turn.credential)
        XCTAssertEqual(turn.username, "\(Int(info.expiresAt.timeIntervalSince1970)):\(info.id.uuidString)")
    }

    /// What the server builds for a session has the fixture's shape and ICE servers.
    func testServerSessionInfoMatchesFixtureShape() async throws {
        let user = try await signUp("Artem")
        let host = try await enrollHost("Artem's Mac mini", owner: user)
        let created = try await createSession(user)
        _ = try await work(host)
        try await assertEqual(try await report(host, session: created.id, .ready), .noContent)

        var body = Data()
        try await app.test(.GET, "v1/sessions/\(created.id.uuidString)", headers: ["Authorization": "Bearer \(user.token)"]) { res async throws in
            body = Data(buffer: res.body)
        }
        let fixture = try Data(contentsOf: Self.directory.appendingPathComponent("session-ready.json"))
        XCTAssertEqual(try keyPaths(json(body)), try keyPaths(json(fixture)))

        let info = try JSONDecoder.custom(dates: .iso8601).decode(SessionInfo.self, from: body)
        let fixtureInfo = try JSONDecoder.custom(dates: .iso8601).decode(SessionInfo.self, from: fixture)
        XCTAssertEqual(info.signaling?.iceServers.map(\.urls), fixtureInfo.signaling?.iceServers.map(\.urls))
    }

    // MARK: - Helpers

    private func roundTrip<T: Codable & Sendable>(_ type: T.Type) -> (Data) throws -> Data {
        { data in
            let value = try ContentConfiguration.global.jsonDecoder.decode(T.self, from: data)
            var buffer = ByteBuffer()
            var headers = HTTPHeaders()
            try ContentConfiguration.global.requireEncoder(for: .json).encode(Wrapper(value), to: &buffer, headers: &headers)
            return Data(buffer: buffer)
        }
    }

    private func json(_ data: Data) throws -> NSObject {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as! NSObject
    }

    /// Every key path in a JSON value, e.g. `signaling.iceServers[].urls`.
    private func keyPaths(_ value: Any, prefix: String = "") -> Set<String> {
        switch value {
        case let object as [String: Any]:
            return object.reduce(into: Set<String>()) { result, entry in
                let path = prefix.isEmpty ? entry.key : "\(prefix).\(entry.key)"
                result.insert(path)
                result.formUnion(keyPaths(entry.value, prefix: path))
            }
        case let array as [Any]:
            return array.reduce(into: Set<String>()) { $0.formUnion(keyPaths($1, prefix: "\(prefix)[]")) }
        default:
            return []
        }
    }
}

/// Lets any Codable go through Vapor's content encoder.
private struct Wrapper<T: Codable & Sendable>: Content {
    var value: T
    init(_ value: T) { self.value = value }
    init(from decoder: any Decoder) throws { value = try T(from: decoder) }
    func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
}

extension ContentConfiguration {
    var jsonDecoder: JSONDecoder {
        get throws {
            guard let decoder = try requireDecoder(for: .json) as? JSONDecoder else { throw Abort(.internalServerError) }
            return decoder
        }
    }
}
