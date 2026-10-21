import Foundation

/// Accounts v1 (Vapor control plane): a single team, invites redeemed for a bearer token.
/// v2 (GitHub sign-in, teams) is in `Teams.swift`; the shared types below gained optional v2 fields.
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
    /// v2: team the invite joins, role it grants, and a link to share (`https://<domain>/invite/<code>`).
    public var teamID: UUID?
    public var role: TeamRole?
    public var url: URL?

    public init(code: String, expiresAt: Date, teamID: UUID? = nil, role: TeamRole? = nil, url: URL? = nil) {
        self.code = code
        self.expiresAt = expiresAt
        self.teamID = teamID
        self.role = role
        self.url = url
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
    /// v1 only: admin of the single team. v2 uses ``Team/role``.
    public var isAdmin: Bool
    /// v2: GitHub login and avatar, and the teams the user belongs to.
    public var login: String?
    public var avatarURL: URL?
    public var teams: [Team]?

    public init(id: UUID, name: String, isAdmin: Bool, login: String? = nil, avatarURL: URL? = nil, teams: [Team]? = nil) {
        self.id = id
        self.name = name
        self.isAdmin = isAdmin
        self.login = login
        self.avatarURL = avatarURL
        self.teams = teams
    }
}
