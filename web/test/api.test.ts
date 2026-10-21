// The TypeScript types in src/api.ts against the control plane's JSON fixtures
// (controlplane/Tests/Fixtures, generated from MaccheriProtocol). MACCHERI_FIXTURES overrides the
// directory; without fixtures the suite is skipped.
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { afterEach, describe, expect, test, vi } from 'vitest'
import { API, atLeast, deviceName } from '../src/api'

const dir = process.env.MACCHERI_FIXTURES ?? join(__dirname, '../../controlplane/Tests/Fixtures')
const fixture = (name: string) => JSON.parse(readFileSync(join(dir, `${name}.json`), 'utf8'))

// A shape is a type in src/api.ts spelled out: required keys with their kind, `?` for optional.
type Shape = 'string' | 'number' | 'boolean' | 'uuid' | 'date' | Shape[] | { [key: string]: Shape } | ['?', Shape] | ['enum', ...string[]]
const opt = (s: Shape): Shape => ['?', s]

const TeamRole: Shape = ['enum', 'member', 'admin', 'owner']
const Team: Shape = { id: 'uuid', name: 'string', role: TeamRole }
const DeviceSpec: Shape = { deviceType: 'string', runtime: 'string' }
const ICEServer: Shape = { urls: ['string'], username: opt('string'), credential: opt('string') }
const SignalingInfo: Shape = { url: 'string', token: 'string', iceServers: [ICEServer] }
const SessionInfo: Shape = {
  id: 'uuid', state: ['enum', 'queued', 'starting', 'ready', 'ended', 'failed'], device: opt(DeviceSpec),
  hostID: opt('uuid'), hostName: opt('string'), createdAt: 'date', expiresAt: 'date', signaling: opt(SignalingInfo), message: opt('string'),
  teamID: opt('uuid'),
}
const HostInfo: Shape = {
  id: 'uuid', name: 'string', ownerName: 'string', online: 'boolean',
  hardware: { model: 'string', chip: 'string', cpuCount: 'number', memoryBytes: 'number', macOSVersion: 'string' },
  capacity: opt({ freeSlots: 'number', warmVMs: 'number', images: ['string'], labels: ['string'], devices: [DeviceSpec] }),
  teamID: opt('uuid'),
}
const CreateSessionRequest: Shape = { device: opt(DeviceSpec), hostID: opt('uuid'), teamID: opt('uuid') }
const UserInfo: Shape = { id: 'uuid', name: 'string', isAdmin: 'boolean', login: opt('string'), avatarURL: opt('string'), teams: opt([Team]) }
const Invite: Shape = { code: 'string', expiresAt: 'date', teamID: opt('uuid'), role: opt(TeamRole), url: opt('string') }
const TeamMember: Shape = { userID: 'uuid', login: 'string', name: 'string', avatarURL: opt('string'), role: TeamRole }
const GitHubInstallation: Shape = { installationID: 'number', account: 'string', repositorySelection: 'string' }

function check(value: unknown, shape: Shape, path = '$'): string[] {
  if (Array.isArray(shape) && shape[0] === '?') return value === undefined || value === null ? [] : check(value, shape[1] as Shape, path)
  if (Array.isArray(shape) && shape[0] === 'enum') return shape.includes(value as string) && value !== 'enum' ? [] : [`${path}: ${JSON.stringify(value)} is not one of ${shape.slice(1)}`]
  if (Array.isArray(shape)) return Array.isArray(value) ? value.flatMap((v, i) => check(v, shape[0] as Shape, `${path}[${i}]`)) : [`${path}: not an array`]
  if (typeof shape === 'object') {
    if (typeof value !== 'object' || value === null) return [`${path}: not an object`]
    const extra = Object.keys(value).filter((k) => !(k in shape)).map((k) => `${path}.${k}: not in the TypeScript type`)
    return [...extra, ...Object.entries(shape).flatMap(([k, s]) => check((value as Record<string, unknown>)[k], s, `${path}.${k}`))]
  }
  switch (shape) {
    case 'uuid': return typeof value === 'string' && /^[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}$/.test(value) ? [] : [`${path}: not an uppercase UUID`]
    case 'date': return typeof value === 'string' && !Number.isNaN(Date.parse(value)) ? [] : [`${path}: not an ISO 8601 date`]
    default: return typeof value === shape ? [] : [`${path}: not a ${shape}`]
  }
}

const shapes: Record<string, Shape> = {
  'session-queued': SessionInfo, 'session-starting': SessionInfo, 'session-ready': SessionInfo, 'session-ended': SessionInfo, 'session-failed': SessionInfo,
  hosts: [HostInfo],
  'create-session-request': CreateSessionRequest,
  'create-session-request-any': CreateSessionRequest,
  'redeem-invite-request': { code: 'string', name: 'string' },
  'user-token': { userID: 'uuid', token: 'string' },
  'user-info': UserInfo,
  invite: Invite,
  'signal-offer': { offer: { sdp: 'string' } },
  'signal-answer': { answer: { sdp: 'string' } },
  'signal-candidate': { candidate: { candidate: 'string', sdpMid: opt('string'), sdpMLineIndex: opt('number') } },
  'signal-candidate-end': { candidate: { candidate: 'string', sdpMid: opt('string'), sdpMLineIndex: opt('number') } },
  'signal-bye': { bye: { reason: opt('string') } },
  'signal-bye-empty': { bye: { reason: opt('string') } },
}

// Accounts v2 (Teams.swift). The Go control plane's fixtures; each is checked once it exists.
const v2Shapes: Record<string, Shape> = {
  'user-info-v2': UserInfo, 'invite-v2': Invite, team: Team, teams: [Team], 'create-team-request': { name: 'string' },
  'team-member': TeamMember, 'team-members': [TeamMember], 'create-invite-request': { role: TeamRole },
  'host-enrollment-code': { code: 'string', expiresAt: 'date' }, 'github-link': { url: 'string' },
  'github-installation': GitHubInstallation, 'github-installations': [GitHubInstallation],
  'session-ready-v2': SessionInfo, 'hosts-v2': [HostInfo], 'create-session-request-v2': CreateSessionRequest,
}

describe.skipIf(!existsSync(dir))('API types match the control plane fixtures', () => {
  test.each(Object.entries(shapes))('%s', (name, shape) => {
    expect(check(fixture(name), shape)).toEqual([])
  })

  test.each(Object.entries(v2Shapes))('%s (v2)', (name, shape) => {
    if (!existsSync(join(dir, `${name}.json`))) return
    expect(check(fixture(name), shape)).toEqual([])
  })

  test('every fixture the web client reads is covered', () => {
    const relevant = readdirSync(dir).filter((f) => /^(session-[a-z]+|hosts|signal-.*|user-.*|invite|redeem-.*|create-session-.*)\.json$/.test(f) && !f.startsWith('session-state'))
    expect(relevant.map((f) => f.replace(/\.json$/, '')).filter((n) => !(n in shapes) && !(n in v2Shapes))).toEqual([])
  })
})

test('device names', () => {
  expect(deviceName({ deviceType: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-27-2' })).toBe('iPhone 17 Pro · iOS 27.2')
})

test('roles compare like TeamRole', () => {
  expect(atLeast('owner', 'admin')).toBe(true)
  expect(atLeast('admin', 'admin')).toBe(true)
  expect(atLeast('member', 'admin')).toBe(false)
})

describe('requests', () => {
  const calls: { url: string; init: RequestInit }[] = []
  function respond(response: Partial<Response> & { status: number }) {
    calls.length = 0
    vi.stubGlobal('fetch', async (url: string, init: RequestInit) => {
      calls.push({ url, init })
      return { ok: response.status < 300 && response.status >= 200, type: 'basic', json: async () => ({}), text: async () => '', ...response }
    })
  }
  afterEach(() => vi.unstubAllGlobals())
  const memory = (): Storage => {
    const m = new Map<string, string>()
    return { getItem: (k) => m.get(k) ?? null, setItem: (k, v) => void m.set(k, v), removeItem: (k) => void m.delete(k) } as Storage
  }

  test('changing requests carry the CSRF header and cookies; reads only cookies', async () => {
    respond({ status: 200 })
    const api = new API('', memory())
    await api.createTeam({ name: 'A' })
    await api.teams()
    const [post, get] = calls.map((c) => c.init)
    expect(post.method).toBe('POST')
    expect((post.headers as Record<string, string>)['X-Maccheri-CSRF']).toBe('1')
    expect(post.credentials).toBe('same-origin')
    expect((get.headers as Record<string, string>)['X-Maccheri-CSRF']).toBeUndefined()
    expect((get.headers as Record<string, string>).Authorization).toBeUndefined()
  })

  test('v2 paths', async () => {
    respond({ status: 200 })
    const api = new API('', memory())
    const team = '6F1E0340-0000-4000-8000-000000000001'
    await api.acceptInvite('a/b')
    await api.createTeamInvite(team, { role: 'admin' })
    await api.createHostCode(team)
    await api.linkGitHub(team)
    await api.logout()
    expect(calls.map((c) => `${c.init.method} ${c.url}`)).toEqual([
      'POST /v1/invites/a%2Fb/accept', `POST /v1/teams/${team}/invites`, `POST /v1/teams/${team}/host-codes`,
      `POST /v1/teams/${team}/github/link`, 'POST /auth/logout',
    ])
    expect(calls[1].init.body).toBe('{"role":"admin"}')
    expect(api.githubLoginURL('/?invite=x')).toBe('/auth/github/login?return_to=%2F%3Finvite%3Dx')
  })

  test('a v1 token goes as a bearer', async () => {
    respond({ status: 200 })
    const api = new API('', memory())
    api.token = 'secret'
    await api.hosts()
    expect((calls[0].init.headers as Record<string, string>).Authorization).toBe('Bearer secret')
  })

  test('GitHub sign-in is there only when the login path redirects', async () => {
    const api = new API('', memory())
    respond({ status: 0, type: 'opaqueredirect' })
    expect(await api.hasGitHubSignIn()).toBe(true)
    expect(calls[0].init.redirect).toBe('manual')
    respond({ status: 404 })
    expect(await api.hasGitHubSignIn()).toBe(false)
    // The v1 control plane's catch-all serves the web client for unknown paths.
    respond({ status: 200 })
    expect(await api.hasGitHubSignIn()).toBe(false)
  })
})
