import Foundation
import MaccheriProtocol
import Testing
@testable import AgentCore

/// Answers every request with `EnrollStub.response` and remembers what was asked.
final class EnrollStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var response: (status: Int, body: Data) = (200, Data())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        Self.lastBody = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let http = HTTPURLResponse(url: request.url!, statusCode: Self.response.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EnrollStub.self]
        return URLSession(configuration: configuration)
    }
}

@Suite(.serialized)
struct EnrollmentTests {
    let base = URL(string: "https://maccheri.example.com")!
    let request = HostEnrollRequest(name: "Test Mac", hardware: HostHardware(model: "Mac16,10", chip: "M4", cpuCount: 10, memoryBytes: 32 << 30, macOSVersion: "27.0"))

    @Test func recognisesCodes() {
        #expect(EnrollmentSecret("  hc_abc123\n") == .code("hc_abc123"))
        #expect(EnrollmentSecret("s3cret") == .sharedToken("s3cret"))
    }

    @Test func codeGoesInTheBodyWithoutBearer() async throws {
        let team = UUID()
        let enrollment = HostEnrollment(hostID: UUID(), agentToken: "agent", teamID: team, teamName: "Mobile")
        EnrollStub.response = (200, try JSONEncoder.maccheri.encode(enrollment))
        let result = try await ControlPlaneClient.enroll(baseURL: base, secret: .code("hc_abc"), request, session: EnrollStub.session)

        #expect(result == enrollment)
        let sent = try #require(EnrollStub.lastRequest)
        #expect(sent.url?.path() == HostAPI.enrollPath)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try JSONDecoder.maccheri.decode(HostEnrollRequest.self, from: try #require(EnrollStub.lastBody))
        #expect(body.code == "hc_abc")
        let credentials = AgentCredentials(controlPlane: base, enrollment: result)
        #expect(credentials.teamName == "Mobile" && credentials.teamID == team)
    }

    @Test func sharedTokenGoesInTheHeader() async throws {
        EnrollStub.response = (200, try JSONEncoder.maccheri.encode(HostEnrollment(hostID: UUID(), agentToken: "agent")))
        _ = try await ControlPlaneClient.enroll(baseURL: base, secret: .sharedToken("shared"), request, session: EnrollStub.session)

        #expect(EnrollStub.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer shared")
        let body = try JSONDecoder.maccheri.decode(HostEnrollRequest.self, from: try #require(EnrollStub.lastBody))
        #expect(body.code == nil)
    }

    @Test func rejectedCodeIsUnauthorized() async throws {
        EnrollStub.response = (401, Data("{}".utf8))
        await #expect(throws: ControlPlaneError.unauthorized) {
            try await ControlPlaneClient.enroll(baseURL: base, secret: .code("hc_old"), request, session: EnrollStub.session)
        }
    }

    @Test func oldKeychainEntriesStillDecode() throws {
        let v1 = #"{"controlPlane":"https://maccheri.example.com","hostID":"\#(UUID().uuidString)","agentToken":"t"}"#
        let credentials = try JSONDecoder().decode(AgentCredentials.self, from: Data(v1.utf8))
        #expect(credentials.teamName == nil)
    }
}
