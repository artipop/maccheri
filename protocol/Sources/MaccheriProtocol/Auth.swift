import Foundation

/// Team members and their tokens. Version 1 has a single team: whoever runs the control plane
/// creates invites, people redeem them for a bearer token.
///
///     POST /v1/invites          (user token)  → Invite
///     POST /v1/auth/redeem      RedeemInviteRequest → UserToken
///     GET  /v1/me               (user token)  → UserInfo
///
/// Every `/v1/...` call except `redeem` needs `Authorization: Bearer <UserToken.token>`.
public enum AuthAPI {
    public static let invitesPath = "/v1/invites"
    public static let redeemPath = "/v1/auth/redeem"
    public static let mePath = "/v1/me"
}

public struct Invite: Codable, Sendable, Equatable {
    /// One-time code, given to the new member out of band.
    public var code: String
    public var expiresAt: Date

    public init(code: String, expiresAt: Date) {
        self.code = code
        self.expiresAt = expiresAt
    }
}

public struct RedeemInviteRequest: Codable, Sendable, Equatable {
    public var code: String
    /// Display name shown to other team members.
    public var name: String

    public init(code: String, name: String) {
        self.code = code
        self.name = name
    }
}

public struct UserToken: Codable, Sendable, Equatable {
    public var userID: UUID
    public var token: String

    public init(userID: UUID, token: String) {
        self.userID = userID
        self.token = token
    }
}

public struct UserInfo: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    public var isAdmin: Bool

    public init(id: UUID, name: String, isAdmin: Bool) {
        self.id = id
        self.name = name
        self.isAdmin = isAdmin
    }
}
