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
