import MaccheriProtocol
import XCTVapor
@testable import ControlPlane

final class SessionTests: ControlPlaneTestCase {
    /// The M1 scenario with a fake agent: queued → starting → ready → ended, then teardown signals.
    func testSessionEndToEnd() async throws {
        let user = try await signUp("Viewer")
        let host = try await enrollHost("Mac mini", owner: user)

        let created = try await createSession(user)
        XCTAssertEqual(created.state, .queued)
        XCTAssertNil(created.signaling)
        XCTAssertEqual(created.expiresAt, clock.now.addingTimeInterval(3600))

        let lease = try await unwrap(try await work(host)?.simulator)
        XCTAssertEqual(lease.sessionID, created.id)
        XCTAssertEqual(lease.device, .iPhone17Pro)
        XCTAssertEqual(lease.image, "test-image")
        XCTAssertEqual(lease.timeoutSeconds, 3600)
        XCTAssertEqual(lease.signaling.url.absoluteString,
                       "wss://maccheri.example/v1/sessions/\(created.id.uuidString)/signal?role=host&token=\(lease.signaling.token)")

        var info = try await session(created.id, user: user)
        XCTAssertEqual(info.state, .starting)
        XCTAssertEqual(info.hostID, host.hostID)
        XCTAssertEqual(info.hostName, "Mac mini")
        let viewer = try XCTUnwrap(info.signaling)
        XCTAssertNotEqual(viewer.token, lease.signaling.token, "one token per role")
        XCTAssertTrue(viewer.url.absoluteString.contains("role=viewer"))
        XCTAssertEqual(viewer.iceServers.count, 2)

        try await assertEqual(try await report(host, session: created.id, .starting), .noContent)
        try await assertEqual(try await report(host, session: created.id, .ready), .noContent)
        info = try await session(created.id, user: user)
        XCTAssertEqual(info.state, .ready)

        try await assertEqual(try await status(.DELETE, "v1/sessions/\(created.id.uuidString)", token: user.token), .noContent)
        info = try await session(created.id, user: user)
        XCTAssertEqual(info.state, .ended)
        XCTAssertEqual(info.message, "ended by user")
        XCTAssertNil(info.signaling)

        // The host learns it from the heartbeat until it acknowledges with a state report (410).
        try await assertEqual(try await heartbeat(host).endedSessions, [created.id])
        try await assertEqual(try await heartbeat(host).endedSessions, [created.id])
        try await assertEqual(try await report(host, session: created.id, .ready), .gone)
        try await assertEqual(try await heartbeat(host).endedSessions, [])
    }

    func testAgentReportsEndAndFailure() async throws {
        let user = try await signUp("Viewer")
        let host = try await enrollHost("mini", owner: user, capacity: Self.capacity(freeSlots: 2))
        let a = try await createSession(user)
        let b = try await createSession(user)
        _ = try await work(host)
        _ = try await work(host)

        try await assertEqual(try await report(host, session: a.id, .ended, message: "viewer left"), .noContent)
        try await assertEqual(try await report(host, session: b.id, .failed), .noContent)
        try await assertEqual(try await session(a.id, user: user).message, "viewer left")
        try await assertEqual(try await session(b.id, user: user).state, .failed)
        try await assertEqual(try await heartbeat(host).endedSessions, [], "the agent reported these itself")
    }

    func testOtherHostCannotReport() async throws {
        let user = try await signUp("Viewer")
        let host = try await enrollHost("mini", owner: user)
        let other = try await enrollHost("studio", owner: user)
        let created = try await createSession(user, CreateSessionRequest(hostID: host.hostID))
        try await assertNil(try await work(other), "pinned to the other host")
        _ = try await work(host)
        try await assertEqual(try await report(other, session: created.id, .ready), .notFound)
    }

    func testSessionsArePrivateAndLimited() async throws {
        let alice = try await signUp("Alice", admin: false)
        let bob = try await signUp("Bob", admin: false)
        let first = try await createSession(alice)
        _ = try await createSession(alice)
        try await assertEqual(try await status(.POST, "v1/sessions", CreateSessionRequest(), token: alice.token), .tooManyRequests)
        try await assertEqual(try await status(.GET, "v1/sessions/\(first.id.uuidString)", token: bob.token), .notFound)
        try await assertEqual(try await status(.DELETE, "v1/sessions/\(first.id.uuidString)", token: bob.token), .notFound)

        try await assertEqual(try await status(.DELETE, "v1/sessions/\(first.id.uuidString)", token: alice.token), .noContent)
        _ = try await createSession(alice)
    }

    func testEmptyBodyCreatesSession() async throws {
        let user = try await signUp("Viewer")
        try await app.test(.POST, "v1/sessions", headers: ["Authorization": "Bearer \(user.token)"]) { res async throws in
            XCTAssertEqual(res.status, .ok, res.body.string)
        }
    }

    func testDeviceMatching() async throws {
        let user = try await signUp("Viewer")
        let ipad = DeviceSpec(deviceType: "com.apple.CoreSimulator.SimDeviceType.iPad-Pro-13-inch-M5", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-2")
        let phoneOnly = try await enrollHost("phones", owner: user)
        let both = try await enrollHost("both", owner: user, capacity: Self.capacity(devices: [ipad, .iPhone17Pro]))

        let created = try await createSession(user, CreateSessionRequest(device: ipad))
        try await assertNil(try await work(phoneOnly))
        try await assertEqual(try await work(both)?.simulator?.device, ipad)
        _ = created

        XCTAssertEqual(Dispatcher.device(for: nil, offered: [ipad, .iPhone17Pro]), .iPhone17Pro)
        XCTAssertEqual(Dispatcher.device(for: nil, offered: [ipad]), ipad)
        XCTAssertNil(Dispatcher.device(for: .iPhone17Pro, offered: [ipad]))
    }

    func testWarmHostIsPreferred() async throws {
        let user = try await signUp("Viewer")
        let cold = try await enrollHost("cold", owner: user)
        let warm = try await enrollHost("warm", owner: user, capacity: Self.capacity(freeSlots: 0, warmVMs: 1))
        let created = try await createSession(user)

        try await assertNil(try await work(cold), "a warm host can take it within the grace period")
        try await assertEqual(try await work(warm)?.simulator?.sessionID, created.id)

        // Past the grace period anyone takes it.
        let next = try await createSession(user)
        clock.advance(seconds: 6)
        try await assertEqual(try await work(cold)?.simulator?.sessionID, next.id)
    }

    func testLongPollWakesUpOnNewSession() async throws {
        try await restart { $0.longPollSeconds = 10 }
        let user = try await signUp("Viewer")
        let host = try await enrollHost("mini", owner: user)

        let started = ContinuousClock.now
        let lease = Task { [app = app!] () -> WorkLease? in
            var lease: WorkLease?
            try await app.test(.POST, "agent/v1/work", beforeRequest: { req async throws in
                req.headers.bearerAuthorization = .init(token: host.agentToken)
                try req.content.encode(LeaseRequest(labels: [], freeSlots: 1))
            }) { res async throws in
                if res.status == .ok { lease = try res.content.decode(WorkLease.self) }
            }
            return lease
        }
        try await Task.sleep(for: .milliseconds(300))
        let created = try await createSession(user)
        let leased = try await lease.value
        XCTAssertEqual(leased?.simulator?.sessionID, created.id)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5))
    }

    func testExpiryOfflineHostAndQueueTimeout() async throws {
        let user = try await signUp("Viewer")
        let host = try await enrollHost("mini", owner: user, capacity: Self.capacity(freeSlots: 2))
        let expiring = try await createSession(user)
        _ = try await work(host)
        try await assertEqual(try await report(host, session: expiring.id, .ready), .noContent)

        // Keep the host alive past the session's hour.
        for _ in 0..<(3600 / 30 + 1) {
            clock.advance(seconds: 30)
            _ = try await heartbeat(host)
        }
        try await sweep()
        try await assertEqual(try await session(expiring.id, user: user).state, .ended)
        try await assertEqual(try await session(expiring.id, user: user).message, "expired")
        try await assertEqual(try await heartbeat(host).endedSessions, [expiring.id])

        let orphaned = try await createSession(user)
        _ = try await work(host)
        clock.advance(seconds: TimeInterval(HostAPI.offlineAfterSeconds + 1))
        try await sweep()
        try await assertEqual(try await session(orphaned.id, user: user).state, .failed)
        try await assertEqual(try await session(orphaned.id, user: user).message, "host went offline")

        let unserved = try await createSession(user)
        clock.advance(seconds: 121)
        try await sweep()
        try await assertEqual(try await session(unserved.id, user: user).message, "no host available")
    }
}
