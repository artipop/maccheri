import Foundation

/// Accounts v2: GitHub sign-in and teams that own pools of Macs. Implemented by the Go control plane
/// (task E); the Vapor control plane only knows the v1 shapes in `Auth.swift`.
///
/// Sign-in (browser, not JSON):
///
///     GET  /auth/github/login?return_to=/path   → 302 to GitHub (OAuth of the team's GitHub App)
///     GET  /auth/github/callback                → sets the `maccheri_session` cookie, 302 to return_to
///     POST /auth/logout                         → 204, clears the cookie
///
/// The web client authenticates with that HttpOnly, Secure, SameSite=Lax cookie. Every request that
/// changes state must also carry `X-Maccheri-CSRF: 1`, which a cross-site form can't send. Tools and
/// scripts use personal API tokens instead: `Authorization: Bearer <APIToken.token>`.
///
///     GET    /v1/me                              → UserInfo (with `login`, `avatarURL`, `teams`)
///     POST   /v1/me/tokens         CreateAPITokenRequest → APIToken (the token is shown once)
///     DELETE /v1/me/tokens/{id}                  → 204
///
///     POST   /v1/teams             CreateTeamRequest → Team (the caller becomes owner)
///     GET    /v1/teams                           → [Team]
///     GET    /v1/teams/{id}/members              → [TeamMember]
///     DELETE /v1/teams/{id}/members/{userID}     → 204 (admin+, or yourself to leave)
///     POST   /v1/teams/{id}/invites  CreateInviteRequest → Invite (admin+; `url` is a link to share)
///     POST   /v1/invites/{code}/accept           → Team (signed-in user joins)
///
///     POST   /v1/teams/{id}/host-codes           → HostEnrollmentCode (admin+; paste into Maccheri.app)
///     GET    /v1/teams/{id}/hosts                → [HostInfo]
///
///     POST   /v1/teams/{id}/github/link          → GitHubLink (admin+; open `url` to install the App)
///     GET    /github/setup?installation_id=…&state=…   GitHub redirects here after install; binds the
///                                                       installation to the team, 302 to the web client
///     GET    /v1/teams/{id}/github               → [GitHubInstallation]
///
/// Hosts, sessions and CI jobs belong to a team. A member uses only their team's Macs; a CI job runs
/// only on Macs of the team its GitHub installation is bound to.
public enum TeamsAPI {
    public static let mePath = "/v1/me"
    public static let tokensPath = "/v1/me/tokens"
    public static let teamsPath = "/v1/teams"
    public static func teamPath(_ id: UUID) -> String { "/v1/teams/\(id.uuidString)" }
    public static func membersPath(_ id: UUID) -> String { teamPath(id) + "/members" }
    public static func invitesPath(_ id: UUID) -> String { teamPath(id) + "/invites" }
    public static func acceptInvitePath(code: String) -> String { "/v1/invites/\(code)/accept" }
    public static func hostCodesPath(_ id: UUID) -> String { teamPath(id) + "/host-codes" }
    public static func hostsPath(_ id: UUID) -> String { teamPath(id) + "/hosts" }
    public static func githubLinkPath(_ id: UUID) -> String { teamPath(id) + "/github/link" }
    public static func githubPath(_ id: UUID) -> String { teamPath(id) + "/github" }
    public static let csrfHeader = "X-Maccheri-CSRF"
    public static let sessionCookie = "maccheri_session"
}

public enum TeamRole: String, Codable, Sendable, Comparable {
    case member
    case admin
    case owner

    private var rank: Int {
        switch self {
        case .member: 0
        case .admin: 1
        case .owner: 2
        }
    }

    public static func < (lhs: TeamRole, rhs: TeamRole) -> Bool { lhs.rank < rhs.rank }
}

public struct Team: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    /// The caller's role in this team.
    public var role: TeamRole

    public init(id: UUID, name: String, role: TeamRole) {
        self.id = id
        self.name = name
        self.role = role
    }
}

public struct CreateTeamRequest: Codable, Sendable, Equatable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

public struct TeamMember: Codable, Sendable, Equatable {
    public var userID: UUID
    /// GitHub login.
    public var login: String
    public var name: String
    public var avatarURL: URL?
    public var role: TeamRole

    public init(userID: UUID, login: String, name: String, avatarURL: URL?, role: TeamRole) {
        self.userID = userID
        self.login = login
        self.name = name
        self.avatarURL = avatarURL
        self.role = role
    }
}

public struct CreateInviteRequest: Codable, Sendable, Equatable {
    /// Role the invitee gets; `owner` is not allowed.
    public var role: TeamRole

    public init(role: TeamRole = .member) {
        self.role = role
    }
}

public struct HostEnrollmentCode: Codable, Sendable, Equatable {
    /// One-time code for `HostEnrollRequest.code`; short-lived.
    public var code: String
    public var expiresAt: Date

    public init(code: String, expiresAt: Date) {
        self.code = code
        self.expiresAt = expiresAt
    }
}

public struct CreateAPITokenRequest: Codable, Sendable, Equatable {
    public var name: String

    public init(name: String) {
        self.name = name
    }
}

public struct APIToken: Codable, Sendable, Equatable {
    public var id: UUID
    public var name: String
    /// Present only in the response that created it.
    public var token: String?
    public var createdAt: Date

    public init(id: UUID, name: String, token: String?, createdAt: Date) {
        self.id = id
        self.name = name
        self.token = token
        self.createdAt = createdAt
    }
}

public struct GitHubLink: Codable, Sendable, Equatable {
    /// `https://github.com/apps/<slug>/installations/new?state=…`; the state binds the installation to the team.
    public var url: URL

    public init(url: URL) {
        self.url = url
    }
}

public struct GitHubInstallation: Codable, Sendable, Equatable {
    public var installationID: Int64
    /// User or organisation the App is installed on.
    public var account: String
    /// `all` or `selected`.
    public var repositorySelection: String

    public init(installationID: Int64, account: String, repositorySelection: String) {
        self.installationID = installationID
        self.account = account
        self.repositorySelection = repositorySelection
    }
}
