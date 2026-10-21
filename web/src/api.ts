// Control plane API, as much as the web client needs. Mirrors protocol/Sources/MaccheriProtocol
// (Auth.swift, Hosts.swift, Sessions.swift, Signaling.swift); the JSON is what Swift's Codable
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
  isAdmin: boolean
}

export interface Invite {
  code: string
  expiresAt: DateString
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

/**
 * REST client. The control plane serves this page, so paths are relative to the page's origin
 * unless `base` says otherwise (dev mode against another control plane).
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
    if (this.token) headers['Authorization'] = `Bearer ${this.token}`
    const response = await fetch(this.base + path, {
      method, headers, body: body === undefined ? undefined : JSON.stringify(body), ...init,
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

  async redeem(request: RedeemInviteRequest): Promise<UserToken> {
    const token = await this.call<UserToken>('POST', '/v1/auth/redeem', request)
    this.token = token.token
    return token
  }

  me() { return this.call<UserInfo>('GET', '/v1/me') }
  createInvite() { return this.call<Invite>('POST', '/v1/invites') }
  hosts() { return this.call<HostInfo[]>('GET', '/v1/hosts') }
  createSession(request: CreateSessionRequest) { return this.call<SessionInfo>('POST', '/v1/sessions', request) }
  session(id: UUID) { return this.call<SessionInfo>('GET', `/v1/sessions/${id}`) }

  /** `keepalive` lets the request outlive the page (closing the tab). */
  endSession(id: UUID, keepalive = false) {
    return this.call<void>('DELETE', `/v1/sessions/${id}`, undefined, { keepalive })
  }
}
