import Foundation
import MaccheriProtocol
import Security

/// What enrollment produced, kept in the login keychain so the token never sits in a plist.
public struct AgentCredentials: Codable, Sendable, Equatable {
    public var controlPlane: URL
    public var hostID: UUID
    public var agentToken: String
    /// v2: the team the Mac serves; nil after a v1 (shared token) enrollment.
    public var teamID: UUID?
    public var teamName: String?

    public init(controlPlane: URL, hostID: UUID, agentToken: String, teamID: UUID? = nil, teamName: String? = nil) {
        self.controlPlane = controlPlane
        self.hostID = hostID
        self.agentToken = agentToken
        self.teamID = teamID
        self.teamName = teamName
    }

    public init(controlPlane: URL, enrollment: HostEnrollment) {
        self.init(controlPlane: controlPlane, hostID: enrollment.hostID, agentToken: enrollment.agentToken, teamID: enrollment.teamID, teamName: enrollment.teamName)
    }

    static let service = "dev.maccheri.agent"
    static let account = "host"

    public static func load() -> AgentCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(AgentCredentials.self, from: data)
    }

    public func save() throws {
        let data = try JSONEncoder().encode(self)
        Self.delete()
        let item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: Self.account,
            kSecAttrLabel as String: "Maccheri host token",
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(status: status)
        }
    }

    public static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

public struct KeychainError: Error, CustomStringConvertible {
    public var status: OSStatus
    public var description: String { "keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "\(status)")" }
}
