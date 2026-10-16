import Foundation
import MaccheriProtocol

public protocol JobSource: Sendable {
    func lease(_ request: LeaseRequest) async throws -> JobLease?
    func complete(jobID: UUID, _ request: CompleteRequest) async throws
}

public struct ControlPlaneClient: JobSource {
    public let baseURL: URL
    public let token: String
    public let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func lease(_ request: LeaseRequest) async throws -> JobLease? {
        let (data, response) = try await post(AgentAPI.leasePath, body: request)
        switch response.statusCode {
        case 200: return try JSONDecoder().decode(JobLease.self, from: data)
        case 204: return nil
        default: throw HTTPError(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
    }

    public func complete(jobID: UUID, _ request: CompleteRequest) async throws {
        let (data, response) = try await post(AgentAPI.completePath(jobID: jobID), body: request)
        guard (200..<300).contains(response.statusCode) else {
            throw HTTPError(status: response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
    }

    private func post(_ path: String, body: some Encodable) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        return (data, response as! HTTPURLResponse)
    }
}

public struct HTTPError: Error, CustomStringConvertible {
    public var status: Int
    public var body: String
    public var description: String { "HTTP \(status): \(body)" }
}
