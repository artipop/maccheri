import Foundation
import MaccheriProtocol

/// The agent's half of the control plane API (`Hosts.swift`, `Work.swift`).
public protocol ControlPlane: Sendable {
    func heartbeat(_ heartbeat: Heartbeat) async throws -> HeartbeatResponse
    /// Long-polls for up to ``WorkAPI/longPollSeconds``; nil when there is nothing to do.
    func work(_ request: LeaseRequest) async throws -> WorkLease?
    func complete(jobID: UUID, _ request: CompleteRequest) async throws
    /// Throws ``ControlPlaneError/sessionGone`` when the control plane has already ended the session.
    func report(sessionID: UUID, _ report: SessionStateReport) async throws
}

public enum ControlPlaneError: Error, Equatable, CustomStringConvertible {
    /// `410 Gone` on a state report.
    case sessionGone
    case unauthorized
    case http(status: Int, body: String)

    public var description: String {
        switch self {
        case .sessionGone: "session already ended"
        case .unauthorized: "the control plane rejected the token"
        case let .http(status, body): "HTTP \(status): \(body)"
        }
    }
}

/// What the owner pastes to enroll a Mac.
public enum EnrollmentSecret: Sendable, Equatable {
    /// v2: a one-time code an admin created for the team (`POST /v1/teams/{id}/host-codes`).
    case code(String)
    /// v1 (Vapor): the control plane's shared token, sent as `Authorization: Bearer`.
    case sharedToken(String)

    public static let codePrefix = "hc_"

    /// A code if it looks like one, otherwise the shared token.
    public init(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self = text.hasPrefix(Self.codePrefix) ? .code(text) : .sharedToken(text)
    }

    public var isCode: Bool {
        if case .code = self { true } else { false }
    }
}

public struct ControlPlaneClient: ControlPlane {
    public let baseURL: URL
    public let token: String
    public let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    /// Registers this Mac with a team's enrollment code (v2) or the shared token (v1); the result goes
    /// into ``AgentCredentials``.
    public static func enroll(baseURL: URL, secret: EnrollmentSecret, _ request: HostEnrollRequest, session: URLSession = .shared) async throws -> HostEnrollment {
        var request = request
        let client: ControlPlaneClient
        switch secret {
        case let .code(code):
            // v2: the code says which team; no bearer token.
            request.code = code
            client = ControlPlaneClient(baseURL: baseURL, token: "", session: session)
        case let .sharedToken(token):
            request.code = nil
            client = ControlPlaneClient(baseURL: baseURL, token: token, session: session)
        }
        let (data, response) = try await client.post(HostAPI.enrollPath, body: request)
        try check(response, data)
        return try JSONDecoder.maccheri.decode(HostEnrollment.self, from: data)
    }

    public func heartbeat(_ heartbeat: Heartbeat) async throws -> HeartbeatResponse {
        let (data, response) = try await post(HostAPI.heartbeatPath, body: heartbeat)
        try Self.check(response, data)
        // An older control plane answers 204.
        guard !data.isEmpty else { return HeartbeatResponse() }
        return try JSONDecoder.maccheri.decode(HeartbeatResponse.self, from: data)
    }

    public func work(_ request: LeaseRequest) async throws -> WorkLease? {
        let (data, response) = try await post(WorkAPI.workPath, body: request, timeout: TimeInterval(WorkAPI.longPollSeconds + 15))
        if response.statusCode == 204 { return nil }
        try Self.check(response, data)
        return try JSONDecoder.maccheri.decode(WorkLease.self, from: data)
    }

    public func complete(jobID: UUID, _ request: CompleteRequest) async throws {
        let (data, response) = try await post(AgentAPI.completePath(jobID: jobID), body: request)
        try Self.check(response, data)
    }

    public func report(sessionID: UUID, _ report: SessionStateReport) async throws {
        let (data, response) = try await post(WorkAPI.sessionStatePath(sessionID: sessionID), body: report)
        if response.statusCode == 410 { throw ControlPlaneError.sessionGone }
        try Self.check(response, data)
    }

    private static func check(_ response: HTTPURLResponse, _ data: Data) throws {
        switch response.statusCode {
        case 200..<300: return
        case 401, 403: throw ControlPlaneError.unauthorized
        default: throw ControlPlaneError.http(status: response.statusCode, body: String(decoding: data.prefix(500), as: UTF8.self))
        }
    }

    private func post(_ path: String, body: some Encodable, timeout: TimeInterval = 30) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder.maccheri.encode(body)
        let (data, response) = try await session.data(for: request)
        return (data, response as! HTTPURLResponse)
    }
}

extension JSONEncoder {
    /// Dates as ISO 8601, as everywhere in the API.
    public static var maccheri: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    public static var maccheri: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
