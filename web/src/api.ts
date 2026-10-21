// Control plane API, as much as the web client needs. Mirrors protocol/Sources/MaccheriProtocol
// (Auth.swift, Teams.swift, Hosts.swift, Sessions.swift, Signaling.swift); the JSON is what Swift's Codable
// produces: dates in ISO 8601, UUIDs as uppercase strings, enums with data as `{"case":{…}}`.
// Checked against the control plane's JSON fixtures in test/api.test.ts.

export type UUID = string
/** ISO 8601. */
export type DateString = string

// Auth.swift

export interface RedeemInviteRequest {
  code: string
  name: string
}

export interface UserToken {
  userID: UUID
  token: string
}

export interface UserInfo {
  id: UUID
  name: string
  /** v1 only; v2 has `Team.role`. */
  isAdmin: boolean
  /** v2: GitHub login, avatar and teams. */
  login?: string | null
  avatarURL?: string | null
  teams?: Team[] | null
}

export interface Invite {
  code: string
  expiresAt: DateString
  /** v2: the team it joins, the role it grants, a link to share. */
  teamID?: UUID | null
  role?: TeamRole | null
  url?: string | null
}

// Teams.swift (accounts v2)

export type TeamRole = 'member' | 'admin' | 'owner'

const roleRank: Record<TeamRole, number> = { member: 0, admin: 1, owner: 2 }
/** `TeamRole`'s `Comparable`: is `role` at least `minimum`? */
export const atLeast = (role: TeamRole, minimum: TeamRole) => roleRank[role] >= roleRank[minimum]

export interface Team {
  id: UUID
  name: string
  /** The caller's role in this team. */
  role: TeamRole
}

export interface CreateTeamRequest {
  name: string
}

export interface TeamMember {
  userID: UUID
  login: string
  name: string
  avatarURL?: string | null
  role: TeamRole
}

export interface CreateInviteRequest {
  /** `owner` is not allowed. */
  role: TeamRole
}

export interface HostEnrollmentCode {
  code: string
  expiresAt: DateString
}

export interface CreateAPITokenRequest {
  name: string
}

export interface APIToken {
  id: UUID
  name: string
  token?: string | null
  createdAt: DateString
}

export interface GitHubLink {
  url: string
}

export interface GitHubInstallation {
  installationID: number
  account: string
  repositorySelection: string
}

// Hosts.swift

export interface HostHardware {
  model: string
  chip: string
  cpuCount: number
  memoryBytes: number
  macOSVersion: string
}

export interface HostCapacity {
  freeSlots: number
  warmVMs: number
  images: string[]
  labels: string[]
  devices: DeviceSpec[]
}

export interface HostInfo {
  id: UUID
  name: string
  ownerName: string
  hardware: HostHardware
  online: boolean
  capacity?: HostCapacity | null
  /** v2: owning team. */
  teamID?: UUID | null
}

// Sessions.swift

export interface DeviceSpec {
  deviceType: string
  runtime: string
}

export const iPhone17Pro: DeviceSpec = {
  deviceType: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro',
  runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-27-2',
}

export interface CreateSessionRequest {
  device?: DeviceSpec | null
  hostID?: UUID | null
  /** v2: whose Macs to use; required when the user is in more than one team. */
  teamID?: UUID | null
}

export type SessionState = 'queued' | 'starting' | 'ready' | 'ended' | 'failed'

export interface SessionInfo {
  id: UUID
  state: SessionState
  device?: DeviceSpec | null
  hostID?: UUID | null
  hostName?: string | null
  createdAt: DateString
  expiresAt: DateString
  signaling?: SignalingInfo | null
  message?: string | null
  /** v2: the team whose Mac serves the session. */
  teamID?: UUID | null
}

// Signaling.swift

export type SignalingRole = 'viewer' | 'host'

export interface ICEServer {
  urls: string[]
  username?: string | null
  credential?: string | null
}

export interface SignalingInfo {
  /** `wss://…/v1/sessions/{id}/signal?role=viewer&token=…`, opened as is. */
  url: string
  token: string
  iceServers: ICEServer[]
}

export type SignalMessage =
  | { offer: { sdp: string } }
  | { answer: { sdp: string } }
  | { candidate: { candidate: string; sdpMid?: string | null; sdpMLineIndex?: number | null } }
  | { bye: { reason?: string | null } }

/** Human-readable device name from CoreSimulator identifiers. */
export function deviceName(d: DeviceSpec): string {
  const type = d.deviceType.replace(/^com\.apple\.CoreSimulator\.SimDeviceType\./, '').replace(/-/g, ' ')
  const runtime = d.runtime.replace(/^com\.apple\.CoreSimulator\.SimRuntime\./, '').replace(/-(\d+)-(\d+)$/, ' $1.$2').replace(/-/g, ' ')
  return `${type} · ${runtime}`
}

export class APIError extends Error {
  constructor(readonly status: number, message: string) {
    super(message)
  }
}

const tokenKey = 'maccheri.token'

/** Header every state-changing request carries; a cross-site form can't send it (Teams.swift). */
export const csrfHeader = 'X-Maccheri-CSRF'

/**
 * REST client. The control plane serves this page, so paths are relative to the page's origin
 * unless `base` says otherwise (dev mode against another control plane).
 *
 * Two kinds of accounts: v1 (Vapor, mini-prod) is a bearer token kept in `localStorage` (an invite's
 * token or the team's shared token); v2 (GitHub sign-in) is the `maccheri_session` cookie, which
 * the browser sends by itself. Every request goes out with cookies and, if there is one, the token.
 */
export class API {
  constructor(readonly base = '', private storage: Storage | undefined = globalThis.localStorage) {}

  get token(): string | null {
    return this.storage?.getItem(tokenKey) ?? null
  }

  set token(value: string | null) {
    if (value === null) this.storage?.removeItem(tokenKey)
    else this.storage?.setItem(tokenKey, value)
  }

  private async call<T>(method: string, path: string, body?: unknown, init: RequestInit = {}): Promise<T> {
    const headers: Record<string, string> = {}
    if (body !== undefined) headers['Content-Type'] = 'application/json'
    if (method !== 'GET') headers[csrfHeader] = '1'
    if (this.token) headers['Authorization'] = `Bearer ${this.token}`
    const response = await fetch(this.base + path, {
      method, headers, body: body === undefined ? undefined : JSON.stringify(body), credentials: 'same-origin', ...init,
    })
    if (!response.ok) {
      const text = await response.text().catch(() => '')
      let reason = text
      try { reason = JSON.parse(text).reason ?? text } catch { /* not JSON */ }
      throw new APIError(response.status, reason || `HTTP ${response.status}`)
    }
    if (response.status === 204) return undefined as T
    return await response.json() as T
  }

  // v2 sign-in: the browser goes to GitHub and comes back to `returnTo` with the cookie.

  /** `/auth/github/login?return_to=…`, to navigate to. */
  githubLoginURL(returnTo: string) {
    return `${this.base}/auth/github/login?return_to=${encodeURIComponent(returnTo)}`
  }

  /**
   * Does the control plane have GitHub sign-in (v2)? v2 redirects the login path to GitHub, which
   * `redirect: 'manual'` sees as an opaque redirect without following it. v1 answers 404, or this
   * very page (its catch-all serves `index.html` for client-side routes), so only a redirect counts.
   */
  async hasGitHubSignIn(): Promise<boolean> {
    const response = await fetch(this.githubLoginURL('/'), { redirect: 'manual', credentials: 'same-origin' })
    return response.type === 'opaqueredirect' || (response.status >= 300 && response.status < 400)
  }

  logout() { return this.call<void>('POST', '/auth/logout') }

  // v1

  async redeem(request: RedeemInviteRequest): Promise<UserToken> {
    const token = await this.call<UserToken>('POST', '/v1/auth/redeem', request)
    this.token = token.token
    return token
  }

  me() { return this.call<UserInfo>('GET', '/v1/me') }
  createInvite() { return this.call<Invite>('POST', '/v1/invites') }
  hosts() { return this.call<HostInfo[]>('GET', '/v1/hosts') }

  // v2 teams

  teams() { return this.call<Team[]>('GET', '/v1/teams') }
  createTeam(request: CreateTeamRequest) { return this.call<Team>('POST', '/v1/teams', request) }
  members(team: UUID) { return this.call<TeamMember[]>('GET', `/v1/teams/${team}/members`) }
  createTeamInvite(team: UUID, request: CreateInviteRequest) { return this.call<Invite>('POST', `/v1/teams/${team}/invites`, request) }
  acceptInvite(code: string) { return this.call<Team>('POST', `/v1/invites/${encodeURIComponent(code)}/accept`) }
  createHostCode(team: UUID) { return this.call<HostEnrollmentCode>('POST', `/v1/teams/${team}/host-codes`) }
  teamHosts(team: UUID) { return this.call<HostInfo[]>('GET', `/v1/teams/${team}/hosts`) }
  linkGitHub(team: UUID) { return this.call<GitHubLink>('POST', `/v1/teams/${team}/github/link`) }
  githubInstallations(team: UUID) { return this.call<GitHubInstallation[]>('GET', `/v1/teams/${team}/github`) }

  // Sessions, both

  createSession(request: CreateSessionRequest) { return this.call<SessionInfo>('POST', '/v1/sessions', request) }
  session(id: UUID) { return this.call<SessionInfo>('GET', `/v1/sessions/${id}`) }

  /** `keepalive` lets the request outlive the page (closing the tab). */
  endSession(id: UUID, keepalive = false) {
    return this.call<void>('DELETE', `/v1/sessions/${id}`, undefined, { keepalive })
  }
}
