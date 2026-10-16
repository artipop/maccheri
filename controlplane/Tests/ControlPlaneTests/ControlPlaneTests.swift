import Crypto
import MaccheriProtocol
import XCTVapor
@testable import ControlPlane

final class ControlPlaneTests: XCTestCase {
    private let secret = "s3cret"
    private let agentToken = "agent-token"
    private var app: Application!
    private let provisioner = FakeProvisioner()

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try configure(app, settings: Settings(
            webhookSecret: secret,
            agentTokens: [agentToken],
            runnerLabel: "maccheri",
            defaultImage: "test-image",
            jobTimeoutSeconds: 600,
            github: nil
        ), provisioner: provisioner)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
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
            req.headers.bearerAuthorization = .init(token: agentToken)
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
        try await app.test(.POST, "agent/v1/lease", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: agentToken)
            try req.content.encode(LeaseRequest(labels: ["maccheri"], freeSlots: 1))
        }) { res async throws in
            XCTAssertEqual(res.status, .badGateway)
        }
        let lease = try await leaseJob(labels: ["maccheri"])
        XCTAssertEqual(lease?.githubJobID, 11)
    }

    func testAgentNeedsToken() async throws {
        try await app.test(.POST, "agent/v1/lease") { res async throws in
            XCTAssertEqual(res.status, .unauthorized)
        }
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
        var lease: JobLease?
        try await app.test(.POST, "agent/v1/lease", beforeRequest: { req async throws in
            req.headers.bearerAuthorization = .init(token: agentToken)
            try req.content.encode(LeaseRequest(labels: labels, freeSlots: 1))
        }) { res async throws in
            if res.status == .ok { lease = try res.content.decode(JobLease.self) }
            else { XCTAssertEqual(res.status, .noContent) }
        }
        return lease
    }
}

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

import _CryptoExtras

extension _RSA.Signing.PrivateKey {
    nonisolated(unsafe) static let testKey = try! _RSA.Signing.PrivateKey(keySize: .bits2048)
}
