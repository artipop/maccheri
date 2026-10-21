import MaccheriProtocol
import NIOConcurrencyHelpers
import WebSocketKit
import XCTVapor
@testable import ControlPlane

final class SignalingTests: ControlPlaneTestCase {
    private var port = 0

    override func setUp() async throws {
        try await super.setUp()
        try await startServer()
    }

    override func tearDown() async throws {
        await app.server.shutdown()
        try await super.tearDown()
    }

    private func startServer() async throws {
        app.http.server.configuration.hostname = "127.0.0.1"
        app.http.server.configuration.port = 0
        try await app.server.start(address: nil)
        port = try XCTUnwrap(app.http.server.shared.localAddress?.port)
    }

    func testRelaysBothWaysAndQueuesUntilTheOtherSideJoins() async throws {
        let (user, host, sessionID, hostSignaling) = try await startedSession()
        let viewerSignaling = try await unwrap(try await session(sessionID, user: user).signaling)

        let hostSocket = try await Peer.connect(local(hostSignaling.url), on: app.eventLoopGroup)
        let offer = SignalHub.encode(.offer(sdp: "v=0 offer"))
        try await hostSocket.socket.send(offer)
        let candidate = SignalHub.encode(.candidate(candidate: "candidate:1", sdpMid: "0", sdpMLineIndex: 0))
        try await hostSocket.socket.send(candidate)

        let viewerSocket = try await Peer.connect(local(viewerSignaling.url), on: app.eventLoopGroup)
        let queued = try await viewerSocket.next(2)
        XCTAssertEqual(queued, [offer, candidate], "frames sent before the viewer joined arrive in order, unchanged")

        let answer = SignalHub.encode(.answer(sdp: "v=0 answer"))
        try await viewerSocket.socket.send(answer)
        try await assertEqual(try await hostSocket.next(1), [answer])

        try await assertEqual(try await report(host, session: sessionID, .ready), .noContent)

        // Ending the session sends bye to both and closes them.
        try await assertEqual(try await status(.DELETE, "v1/sessions/\(sessionID.uuidString)", token: user.token), .noContent)
        let bye = SignalHub.encode(.bye(reason: "ended by user"))
        try await assertEqual(try await viewerSocket.next(1), [bye])
        try await assertEqual(try await hostSocket.next(1), [bye])
        try await viewerSocket.socket.onClose.get()
        try await hostSocket.socket.onClose.get()
    }

    func testReconnectReplacesTheOldSocket() async throws {
        let (user, _, sessionID, hostSignaling) = try await startedSession()
        let viewerSignaling = try await unwrap(try await session(sessionID, user: user).signaling)

        let first = try await Peer.connect(local(viewerSignaling.url), on: app.eventLoopGroup)
        let second = try await Peer.connect(local(viewerSignaling.url), on: app.eventLoopGroup)
        try await first.socket.onClose.get()
        XCTAssertEqual(first.socket.closeCode, .unknown(4000))

        let hostSocket = try await Peer.connect(local(hostSignaling.url), on: app.eventLoopGroup)
        let offer = SignalHub.encode(.offer(sdp: "x"))
        try await hostSocket.socket.send(offer)
        try await assertEqual(try await second.next(1), [offer])
        try await second.socket.close()
        try await hostSocket.socket.close()
    }

    func testRejectsWrongTokenRoleAndEndedSessions() async throws {
        let (user, _, sessionID, hostSignaling) = try await startedSession()
        let viewerToken = try await unwrap(try await session(sessionID, user: user).signaling).token
        let base = "ws://127.0.0.1:\(port)/v1/sessions/\(sessionID.uuidString)/signal"

        await assertRejected("\(base)?role=viewer&token=\(hostSignaling.token)")
        await assertRejected("\(base)?role=host&token=\(viewerToken)")
        await assertRejected("\(base)?role=viewer")
        try await assertEqual(try await status(.DELETE, "v1/sessions/\(sessionID.uuidString)", token: user.token), .noContent)
        await assertRejected("\(base)?role=viewer&token=\(viewerToken)")
    }

    // MARK: - Helpers

    private func startedSession() async throws -> (UserToken, HostEnrollment, UUID, SignalingInfo) {
        let user = try await signUp("Viewer")
        let host = try await enrollHost("mini", owner: user)
        let created = try await createSession(user)
        let lease = try await unwrap(try await work(host)?.simulator)
        return (user, host, created.id, lease.signaling)
    }

    /// The signaling URL points at PUBLIC_URL; tests talk to the local server.
    private func local(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = port
        return components.string!
    }

    private func assertRejected(_ url: String, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            let peer = try await Peer.connect(url, on: app.eventLoopGroup)
            try? await peer.socket.close()
            XCTFail("connected to \(url)", file: file, line: line)
        } catch {
            XCTAssertFalse(error is Abort, "expected a refused upgrade, got \(error)", file: file, line: line)
        }
    }
}

/// A test WebSocket client that collects text frames.
final class Peer: Sendable {
    let socket: WebSocket
    private let frames = NIOLockedValueBox<[String]>([])

    private init(socket: WebSocket) {
        self.socket = socket
        socket.onText { [frames] _, text in frames.withLockedValue { $0.append(text) } }
    }

    static func connect(_ url: String, on group: any EventLoopGroup) async throws -> Peer {
        let promise = group.next().makePromise(of: Peer.self)
        WebSocket.connect(to: url, on: group) { socket in
            promise.succeed(Peer(socket: socket))
        }.whenFailure { promise.fail($0) }
        let timeout = group.next().scheduleTask(in: .seconds(5)) {
            promise.fail(Abort(.requestTimeout, reason: "WebSocket connect timed out"))
        }
        defer { timeout.cancel() }
        return try await promise.futureResult.get()
    }

    /// Waits up to 5 s for `count` more frames and returns them.
    func next(_ count: Int) async throws -> [String] {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            let taken = frames.withLockedValue { frames -> [String]? in
                guard frames.count >= count else { return nil }
                defer { frames.removeFirst(count) }
                return Array(frames.prefix(count))
            }
            if let taken { return taken }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw Abort(.requestTimeout, reason: "expected \(count) frames, got \(frames.withLockedValue { $0 })")
    }
}
