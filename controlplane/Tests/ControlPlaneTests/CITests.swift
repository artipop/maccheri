import Crypto
import MaccheriProtocol
import XCTVapor
@testable import ControlPlane

final class CITests: ControlPlaneTestCase {
    private var secret: String { webhookSecret }
    /// The host that polls for CI work in most tests.
    private var host: HostEnrollment!

    override func makeSettings() -> Settings {
        var settings = super.makeSettings()
        settings.longPollSeconds = 0 // answer at once when there is nothing
        return settings
    }

    override func setUp() async throws {
        try await super.setUp()
        host = try await enrollHost("ci", owner: try await signUp("Owner"))
    }

    func testRejectsBadSignature() async throws {
        try await app.test(.POST, "github/webhook", headers: ["X-GitHub-Event": "workflow_job", "X-Hub-Signature-256": "sha256=00"], body: ByteBuffer(string: "{}")) { res async throws in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    func testQueuedJobIsLeasedOnceWithJitConfig() async throws {
        try await sendWorkflowJob(action: "queued", id: 7, labels: ["self-hosted", "macOS", "maccheri"])

        let lease = try await leaseJob(labels: ["maccheri", "macos-27"])
        XCTAssertEqual(lease?.githubJobID, 7)
        XCTAssertEqual(lease?.repository, "octo/repo")
        XCTAssertEqual(lease?.jitConfig, "jit-for-octo/repo")
        XCTAssertEqual(lease?.image, "test-image")
        let calls = await provisioner.calls
        XCTAssertEqual(calls.first?.labels, ["maccheri"], "GitHub's default labels must not be re-registered")

        let second = try await leaseJob(labels: ["maccheri"])
        XCTAssertNil(second)

        try await app.test(.POST, "agent/v1/jobs/\(lease!.jobID.uuidString)/complete", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: host.agentToken)
            try req.content.encode(CompleteRequest(outcome: .finished, durationSeconds: 12))
        }) { res async throws in
            XCTAssertEqual(res.status, .noContent)
        }
    }

    func testIgnoresJobsForOtherRunners() async throws {
        try await sendWorkflowJob(action: "queued", id: 8, labels: ["ubuntu-latest"])
        let lease = try await leaseJob(labels: ["maccheri"])
        XCTAssertNil(lease)
    }

    func testHostWithoutRequiredLabelGetsNothing() async throws {
        try await sendWorkflowJob(action: "queued", id: 9, labels: ["self-hosted", "maccheri", "xcode-27.2"])
        let lease = try await leaseJob(labels: ["maccheri", "xcode-26"])
        XCTAssertNil(lease)
    }

    func testCancelledBeforeLeaseIsDropped() async throws {
        try await sendWorkflowJob(action: "queued", id: 10, labels: ["maccheri"])
        try await sendWorkflowJob(action: "completed", id: 10, labels: ["maccheri"])
        let lease = try await leaseJob(labels: ["maccheri"])
        XCTAssertNil(lease)
    }

    func testFailedProvisioningRequeues() async throws {
        await provisioner.failNext()
        try await sendWorkflowJob(action: "queued", id: 11, labels: ["maccheri"])
        try await assertEqual(try await status(.POST, "agent/v1/work", LeaseRequest(labels: ["maccheri"], freeSlots: 1), token: host.agentToken), .badGateway)
        let lease = try await leaseJob(labels: ["maccheri"])
        XCTAssertEqual(lease?.githubJobID, 11)
    }

    func testJobsSurviveRestart() async throws {
        try await sendWorkflowJob(action: "queued", id: 12, labels: ["maccheri"])
        try await restart()
        let lease = try await leaseJob(labels: ["maccheri"])
        XCTAssertEqual(lease?.githubJobID, 12)
    }

    func testWorkHandsOutCIAfterSimulator() async throws {
        let owner = try await signUp("Owner")
        let host = try await enrollHost("mini", owner: owner)
        try await sendWorkflowJob(action: "queued", id: 13, labels: ["self-hosted", "maccheri"])
        let session = try await createSession(owner)

        let first = try await work(host)
        XCTAssertEqual(first?.simulator?.sessionID, session.id, "a waiting person goes before CI")
        let second = try await work(host)
        XCTAssertEqual(second?.ci?.githubJobID, 13)
        XCTAssertEqual(second?.ci?.jitConfig, "jit-for-octo/repo")

        try await app.test(.POST, "agent/v1/jobs/\(second!.ci!.jobID.uuidString)/complete", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: host.agentToken)
            try req.content.encode(CompleteRequest(outcome: .finished, durationSeconds: 30))
        }) { res async throws in
            XCTAssertEqual(res.status, .noContent)
        }
    }

    func testJobOfOfflineHostIsRequeued() async throws {
        let owner = try await signUp("Owner")
        let host = try await enrollHost("mini", owner: owner)
        try await sendWorkflowJob(action: "queued", id: 14, labels: ["maccheri"])
        try await assertEqual(try await work(host)?.ci?.githubJobID, 14)

        clock.advance(seconds: 60)
        try await sweep()
        let other = try await enrollHost("studio", owner: owner)
        try await assertEqual(try await work(other)?.ci?.githubJobID, 14)
    }

    func testAgentNeedsToken() async throws {
        try await assertEqual(try await status(.POST, "agent/v1/work", LeaseRequest(labels: ["maccheri"], freeSlots: 1), token: nil), .unauthorized)
        try await assertEqual(try await status(.POST, "agent/v1/lease", LeaseRequest(labels: ["maccheri"], freeSlots: 1), token: host.agentToken), .notFound,
                              "the CI-only lease is gone")
    }

    func testJWTShape() throws {
        let key = _RSA.Signing.PrivateKey.testKey
        let jwt = try GitHubAppJWT.make(appID: "123", privateKeyPEM: key.pemRepresentation, now: Date(timeIntervalSince1970: 1_000_000))
        let parts = jwt.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        XCTAssertEqual(String(decoding: Data(base64Encoded: payload)!, as: UTF8.self), #"{"iat":999940,"exp":1000540,"iss":"123"}"#)

        var signature = String(parts[2]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        signature += String(repeating: "=", count: (4 - signature.count % 4) % 4)
        XCTAssertTrue(key.publicKey.isValidSignature(
            _RSA.Signing.RSASignature(rawRepresentation: Data(base64Encoded: signature)!),
            for: Data("\(parts[0]).\(parts[1])".utf8),
            padding: .insecurePKCS1v1_5
        ))
    }

    // MARK: - Helpers

    private func sendWorkflowJob(action: String, id: Int64, labels: [String]) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "action": action,
            "workflow_job": ["id": id, "labels": labels],
            "repository": ["full_name": "octo/repo"],
            "installation": ["id": 99],
        ])
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: Data(secret.utf8)))
        let signature = "sha256=" + mac.map { String(format: "%02x", $0) }.joined()
        try await app.test(.POST, "github/webhook", headers: ["X-GitHub-Event": "workflow_job", "X-Hub-Signature-256": signature], body: ByteBuffer(data: body)) { res async throws in
            XCTAssertEqual(res.status, .accepted)
        }
    }

    private func leaseJob(labels: [String]) async throws -> JobLease? {
        try await work(host, labels: labels)?.ci
    }
}

import _CryptoExtras

extension _RSA.Signing.PrivateKey {
    static let testKey = try! _RSA.Signing.PrivateKey(keySize: .bits2048)
}
