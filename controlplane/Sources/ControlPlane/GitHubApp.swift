import _CryptoExtras
import Foundation
import Vapor

/// Creates a just-in-time runner registration for a repository.
protocol RunnerProvisioner: Sendable {
    func jitConfig(installationID: Int64, repository: String, runnerName: String, labels: [String]) async throws -> String
}

struct GitHubAppCredentials: Sendable {
    var appID: String
    var privateKeyPEM: String
}

/// Talks to the GitHub REST API as a GitHub App installation.
final class GitHubAppProvisioner: RunnerProvisioner {
    private let credentials: GitHubAppCredentials
    private let client: any Client
    private let tokens = InstallationTokenCache()
    private let apiBase = "https://api.github.com"

    init(credentials: GitHubAppCredentials, client: any Client) {
        self.credentials = credentials
        self.client = client
    }

    func jitConfig(installationID: Int64, repository: String, runnerName: String, labels: [String]) async throws -> String {
        let token = try await installationToken(installationID)
        struct Body: Content {
            var name: String
            var runner_group_id: Int
            var labels: [String]
            var work_folder: String
        }
        struct Reply: Content { var encoded_jit_config: String }

        let response = try await client.post(URI(string: "\(apiBase)/repos/\(repository)/actions/runners/generate-jitconfig")) { req in
            req.headers = Self.headers(bearer: token)
            try req.content.encode(Body(name: runnerName, runner_group_id: 1, labels: labels, work_folder: "_work"))
        }
        guard response.status == .created else {
            throw Abort(.badGateway, reason: "generate-jitconfig: \(response.status) \(response.body.map { String(buffer: $0) } ?? "")")
        }
        return try response.content.decode(Reply.self).encoded_jit_config
    }

    private func installationToken(_ installationID: Int64) async throws -> String {
        if let cached = await tokens.token(for: installationID) { return cached }

        struct Reply: Content { var token: String; var expires_at: Date }
        let jwt = try GitHubAppJWT.make(appID: credentials.appID, privateKeyPEM: credentials.privateKeyPEM)
        let response = try await client.post(URI(string: "\(apiBase)/app/installations/\(installationID)/access_tokens")) { req in
            req.headers = Self.headers(bearer: jwt)
        }
        guard response.status == .created else {
            throw Abort(.badGateway, reason: "access_tokens: \(response.status)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let reply = try response.content.decode(Reply.self, using: decoder)
        await tokens.store(reply.token, for: installationID, expiresAt: reply.expires_at)
        return reply.token
    }

    private static func headers(bearer: String) -> HTTPHeaders {
        [
            "Authorization": "Bearer \(bearer)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "maccheri-controlplane",
        ]
    }
}

actor InstallationTokenCache {
    private var entries: [Int64: (token: String, expiresAt: Date)] = [:]

    func token(for installation: Int64, now: Date = Date()) -> String? {
        guard let entry = entries[installation], entry.expiresAt.timeIntervalSince(now) > 300 else { return nil }
        return entry.token
    }

    func store(_ token: String, for installation: Int64, expiresAt: Date) {
        entries[installation] = (token, expiresAt)
    }
}

/// RS256 JWT that authenticates as the App itself (not an installation).
enum GitHubAppJWT {
    static func make(appID: String, privateKeyPEM: String, now: Date = Date()) throws -> String {
        let iat = Int(now.timeIntervalSince1970) - 60 // tolerate clock drift, as GitHub recommends
        let header = #"{"alg":"RS256","typ":"JWT"}"#
        let payload = #"{"iat":\#(iat),"exp":\#(iat + 600),"iss":"\#(appID)"}"#
        let signingInput = base64URL(Data(header.utf8)) + "." + base64URL(Data(payload.utf8))
        let key = try _RSA.Signing.PrivateKey(pemRepresentation: privateKeyPEM)
        let signature = try key.signature(for: Data(signingInput.utf8), padding: .insecurePKCS1v1_5)
        return signingInput + "." + base64URL(signature.rawRepresentation)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
