// A stand-in control plane inside the Vite dev server, so the web client and the host peer can be
// developed without the real one. In-memory.
//
//   npm run dev                      # web client + mock on :5173
//   simstream-peer --guest 127.0.0.1:7300 --control-plane http://localhost:5173 --shared-token dev
//
// Implements the parts of protocol/Sources/MaccheriProtocol the client and the agent use. Two kinds
// of accounts, as the real control planes:
//
// - v2 (default, Teams.swift): GitHub sign-in is faked: /auth/github/login redirects to a form that asks for
//   a login, then sets the `maccheri_session` cookie. Login `dev` owns the seeded team «Dev» with
//   the dev Mac; any other login starts without a team (create one, or open an invite link).
//   Changing requests with the cookie need `X-Maccheri-CSRF: 1`. Teams, members, invites, host
//   codes, a fake GitHub App install (`/github/setup`).
// - v1 (`MOCK_ACCOUNTS=v1`, Auth.swift): any invite code redeems for a token; /auth/* is 404.
//
// Both: the shared token MOCK_SHARED_TOKEN (default `dev`) as a bearer works like a v1 user and
// enrolls hosts into «Dev»; `enroll` with a v2 code enrolls into that code's team. Any unknown agent
// token stands for the dev Mac, so `--agent-token anything` works. /agent/v1/work, state reports,
// heartbeats and the signaling WebSocket. MOCK_ICE="stun:…,turn:user:pass@…" adds ICE servers.
// With VITE_API pointing elsewhere (a real control plane) the mock stays off.

import { randomBytes, randomUUID } from 'node:crypto'
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Plugin } from 'vite'
import { WebSocketServer, type WebSocket } from 'ws'
import type { GitHubInstallation, HostHardware, HostInfo, ICEServer, SessionInfo, SignalingRole, Team, TeamMember, TeamRole, UserInfo } from '../src/api.ts'

const uuid = () => randomUUID().toUpperCase()
const token = () => randomBytes(18).toString('base64url')
// Swift's .iso8601 strategy rejects fractional seconds.
const isoDate = (d: Date) => d.toISOString().replace(/\.\d{3}Z$/, 'Z')
const rank: Record<TeamRole, number> = { member: 0, admin: 1, owner: 2 }

interface Session {
  info: SessionInfo
  tokens: Record<SignalingRole, string>
  sockets: Partial<Record<SignalingRole, WebSocket>>
  /** Frames for a side that hasn't joined yet. */
  queued: Record<SignalingRole, string[]>
  leased: boolean
}

interface User { id: string; login: string; name: string; avatarURL?: string }
interface MockTeam { id: string; name: string; members: Map<string, TeamRole>; installations: GitHubInstallation[] }
interface Host { id: string; name: string; teamID: string; hardware: HostHardware; seen: number }

class HTTPError extends Error {
  constructor(readonly status: number, reason: string) { super(reason) }
}

export function mockControlPlane(): Plugin {
  const v2 = (process.env.MOCK_ACCOUNTS ?? 'v2') !== 'v1'
  const sharedToken = process.env.MOCK_SHARED_TOKEN ?? 'dev'

  const users = new Map<string, User>()
  const bearers = new Map<string, string>() // v1 token → user id
  const cookies = new Map<string, string>() // session cookie → user id
  const teams = new Map<string, MockTeam>()
  const invites = new Map<string, { teamID: string; role: TeamRole; expiresAt: Date }>()
  const hostCodes = new Map<string, { teamID: string; expiresAt: Date }>()
  const hosts = new Map<string, Host>()
  const agentTokens = new Map<string, string>() // agent token → host id
  const sessions = new Map<string, Session>()
  const waiting: { res: ServerResponse; host: Host; origin: string; timer: NodeJS.Timeout }[] = []

  // Seed: user `dev` owning team «Dev» with the dev Mac.
  const devUser: User = { id: uuid(), login: 'dev', name: 'Dev' }
  users.set(devUser.id, devUser)
  const devTeam: MockTeam = { id: uuid(), name: 'Dev', members: new Map([[devUser.id, 'owner']]), installations: [] }
  teams.set(devTeam.id, devTeam)
  const hardware: HostHardware = { model: 'Mac16,10', chip: 'Apple M4', cpuCount: 10, memoryBytes: 16 * 2 ** 30, macOSVersion: '27.0.1' }
  const devHost: Host = { id: uuid(), name: 'Dev Mac', teamID: devTeam.id, hardware, seen: 0 }
  hosts.set(devHost.id, devHost)
  // v1's single team: everyone with a bearer token is in «Dev».
  const sharedUser = { id: devUser.id, name: 'team', isAdmin: true }

  const iceServers = (): ICEServer[] =>
    (process.env.MOCK_ICE ?? '').split(',').filter(Boolean).map((url) => {
      const m = url.match(/^(turns?):([^:]*):([^@]*)@(.*)$/)
      return m ? { urls: [`${m[1]}:${m[4]}`], username: decodeURIComponent(m[2]), credential: decodeURIComponent(m[3]) } : { urls: [url] }
    })

  const secure = !!process.env.DEV_HTTPS_CERT
  const signaling = (s: Session, role: SignalingRole, origin: string) => ({
    url: `${secure ? 'wss' : 'ws'}://${origin}/v1/sessions/${s.info.id}/signal?role=${role}&token=${s.tokens[role]}`,
    token: s.tokens[role],
    iceServers: iceServers(),
  })

  function send(res: ServerResponse, status: number, body?: unknown) {
    res.statusCode = status
    if (body === undefined) return res.end()
    res.setHeader('Content-Type', 'application/json')
    res.end(JSON.stringify(body))
  }

  async function body<T>(req: IncomingMessage): Promise<T> {
    const chunks: Buffer[] = []
    for await (const c of req) chunks.push(c as Buffer)
    return chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : ({} as T)
  }

  const cookie = (req: IncomingMessage) => (req.headers.cookie ?? '').match(/(?:^|;\s*)maccheri_session=([^;]+)/)?.[1]
  const bearer = (req: IncomingMessage) => (req.headers.authorization ?? '').replace(/^Bearer /, '')

  /** The signed-in v2 user (cookie), or nil. Changing requests must carry the CSRF header. */
  function cookieUser(req: IncomingMessage): User | undefined {
    const id = cookies.get(cookie(req) ?? '')
    if (!id) return undefined
    if (req.method !== 'GET' && req.headers['x-maccheri-csrf'] !== '1') throw new HTTPError(403, 'Missing X-Maccheri-CSRF')
    return users.get(id)
  }

  function teamsOf(user: User): Team[] {
    return [...teams.values()].filter((t) => t.members.has(user.id)).map((t) => ({ id: t.id, name: t.name, role: t.members.get(user.id)! }))
  }

  function teamFor(user: User, id: string, minimum: TeamRole = 'member'): MockTeam {
    const team = teams.get(id.toUpperCase())
    const role = team?.members.get(user.id)
    if (!team || !role) throw new HTTPError(404, 'No such team')
    if (rank[role] < rank[minimum]) throw new HTTPError(403, `Needs ${minimum}`)
    return team
  }

  const hostInfo = (h: Host): HostInfo => {
    const online = Date.now() - h.seen < 45_000
    return {
      id: h.id, name: h.name, ownerName: 'dev', hardware: h.hardware, online, teamID: v2 ? h.teamID : undefined,
      capacity: { freeSlots: 1, warmVMs: 1, images: ['macos-27-xcode-27.2'], labels: ['maccheri'], devices: [{ deviceType: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-27-2' }] },
    }
  }

  /** Hands queued sessions to waiting agents of the session's team (and host, if pinned). */
  function dispatch() {
    for (const s of sessions.values()) {
      if (s.leased || s.info.state !== 'queued') continue
      const i = waiting.findIndex((w) => w.host.teamID === (s.info.teamID ?? devTeam.id) && (!s.info.hostID || s.info.hostID === w.host.id))
      if (i < 0) continue
      const [agent] = waiting.splice(i, 1)
      clearTimeout(agent.timer)
      s.leased = true
      s.info.state = 'starting'
      s.info.hostID = agent.host.id
      s.info.hostName = agent.host.name
      s.info.signaling = signaling(s, 'viewer', agent.origin)
      send(agent.res, 200, { simulator: { _0: {
        sessionID: s.info.id, image: 'macos-27-xcode-27.2', device: s.info.device,
        timeoutSeconds: 3600, signaling: signaling(s, 'host', agent.origin),
      } } })
    }
  }

  function end(s: Session, state: 'ended' | 'failed', reason: string) {
    if (s.info.state === 'ended' || s.info.state === 'failed') return
    s.info.state = state
    s.info.message = reason
    for (const role of ['host', 'viewer'] as const) {
      s.sockets[role]?.send(JSON.stringify({ bye: { reason } }))
    }
  }

  // MARK: Fake GitHub sign-in

  function html(res: ServerResponse, page: string) {
    res.setHeader('Content-Type', 'text/html; charset=utf-8')
    res.end(`<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><body style="font:15px system-ui;margin:48px auto;max-width:360px">${page}`)
  }

  function redirect(res: ServerResponse, location: string, setCookie?: string) {
    res.statusCode = 302
    res.setHeader('Location', location)
    if (setCookie) res.setHeader('Set-Cookie', setCookie)
    res.end()
  }

  const escape = (s: string) => s.replace(/[&<>"]/g, (c) => `&#${c.charCodeAt(0)};`)
  const safeReturn = (to: string | null) => (to && to.startsWith('/') && !to.startsWith('//') ? to : '/')

  function auth(path: string, url: URL, res: ServerResponse, req: IncomingMessage): boolean {
    // Like the real one, the login path redirects to "GitHub" (the client detects v2 by that).
    if (path === '/auth/github/login' && req.method === 'GET') {
      redirect(res, `/auth/github/mock?return_to=${encodeURIComponent(safeReturn(url.searchParams.get('return_to')))}`)
      return true
    }
    if (path === '/auth/github/mock' && req.method === 'GET') {
      const to = safeReturn(url.searchParams.get('return_to'))
      html(res, `<h2>Mock GitHub</h2><p>Sign in as (dev owns the team «Dev»):</p>
        <form action="callback"><input type="hidden" name="return_to" value="${escape(to)}">
        <input name="login" value="dev" autofocus> <button>Sign in</button></form>`)
      return true
    }
    if (path === '/auth/github/callback' && req.method === 'GET') {
      const login = (url.searchParams.get('login') ?? 'dev').trim() || 'dev'
      let user = [...users.values()].find((u) => u.login === login)
      if (!user) users.set((user = { id: uuid(), login, name: login[0].toUpperCase() + login.slice(1) }).id, user)
      const session = token()
      cookies.set(session, user.id)
      redirect(res, safeReturn(url.searchParams.get('return_to')), `maccheri_session=${session}; Path=/; HttpOnly; SameSite=Lax${secure ? '; Secure' : ''}`)
      return true
    }
    if (path === '/auth/logout' && req.method === 'POST') {
      cookies.delete(cookie(req) ?? '')
      res.setHeader('Set-Cookie', 'maccheri_session=; Path=/; Max-Age=0')
      send(res, 204)
      return true
    }
    return false
  }

  async function handle(req: IncomingMessage, res: ServerResponse): Promise<boolean> {
    const url = new URL(req.url ?? '/', 'http://x')
    const path = url.pathname
    const method = req.method ?? 'GET'
    const origin = req.headers.host ?? 'localhost:5173'

    if (path.startsWith('/auth/')) {
      // v1 has no such paths; say so rather than letting Vite serve the page.
      if (!v2 || !auth(path, url, res, req)) send(res, 404, { error: true, reason: 'Not Found' })
      return true
    }
    if (path === '/github/setup' && v2) {
      // GitHub's redirect after installing the App; `state` is the team.
      const team = teams.get(url.searchParams.get('state') ?? '')
      team?.installations.push({ installationID: 40_000_000 + Math.floor(Math.random() * 1e6), account: 'dev-org', repositorySelection: 'all' })
      return redirect(res, '/'), true
    }

    if (path.startsWith('/agent/v1/')) {
      const host = hosts.get(agentTokens.get(bearer(req)) ?? '') ?? devHost
      host.seen = Date.now()
      if (method === 'POST' && path === '/agent/v1/work') {
        await body(req)
        const entry = { res, host, origin, timer: setTimeout(() => { waiting.splice(waiting.indexOf(entry), 1); send(res, 204) }, 25_000) }
        waiting.push(entry)
        req.on('close', () => { const i = waiting.indexOf(entry); if (i >= 0) { clearTimeout(entry.timer); waiting.splice(i, 1) } })
        dispatch()
        return true
      }
      const state = path.match(/^\/agent\/v1\/sessions\/([^/]+)\/state$/)
      if (method === 'POST' && state) {
        const s = sessions.get(state[1].toUpperCase())
        const report = await body<{ state: string; message?: string }>(req)
        if (!s) return send(res, 404), true
        if (s.info.state === 'ended' || s.info.state === 'failed') return send(res, 410), true
        if (report.state === 'ready' || report.state === 'starting') s.info.state = report.state
        else end(s, report.state === 'failed' ? 'failed' : 'ended', report.message ?? `host reported ${report.state}`)
        send(res, 204)
        return true
      }
      if (method === 'POST' && path === '/agent/v1/heartbeat') {
        const ended = [...sessions.values()].filter((s) => s.info.state === 'ended' || s.info.state === 'failed').map((s) => s.info.id)
        send(res, 200, { endedSessions: ended })
        return true
      }
      return false
    }

    if (!path.startsWith('/v1/')) return false

    if (method === 'POST' && path === '/v1/hosts/enroll') {
      const request = await body<{ name: string; hardware: HostHardware; code?: string }>(req)
      let teamID: string
      if (request.code) {
        const code = hostCodes.get(request.code)
        if (!code || code.expiresAt < new Date()) return send(res, 401, { error: true, reason: 'Unknown or expired code' }), true
        hostCodes.delete(request.code)
        teamID = code.teamID
      } else if (bearer(req) === sharedToken) {
        teamID = devTeam.id
      } else {
        return send(res, 401, { error: true, reason: 'Unauthorized' }), true
      }
      // The shared token re-enrolls the dev Mac, so the seeded team keeps one host.
      const host = teamID === devTeam.id && !request.code ? devHost : { id: uuid(), name: request.name, teamID, hardware: request.hardware, seen: 0 }
      hosts.set(host.id, host)
      const agentToken = token()
      agentTokens.set(agentToken, host.id)
      const team = teams.get(teamID)!
      return send(res, 200, { hostID: host.id, agentToken, ...(v2 ? { teamID, teamName: team.name } : {}) }), true
    }

    if (method === 'POST' && path === '/v1/auth/redeem') {
      if (v2) return false
      const { name } = await body<{ code: string; name: string }>(req)
      const t = token()
      const user: User = { id: uuid(), login: '', name: name || 'Dev' }
      users.set(user.id, user)
      bearers.set(t, user.id)
      send(res, 200, { userID: user.id, token: t })
      return true
    }

    // Who is calling: a v2 cookie, or a bearer (shared token or a v1 user's token).
    const signedIn = v2 ? cookieUser(req) : undefined
    const b = bearer(req)
    const v1User = b === sharedToken ? sharedUser : bearers.has(b) ? { ...users.get(bearers.get(b)!)!, isAdmin: false } : undefined
    if (!signedIn && !v1User) return send(res, 401, { error: true, reason: 'Unauthorized' }), true

    if (method === 'GET' && path === '/v1/me') {
      if (!signedIn) return send(res, 200, { id: v1User!.id, name: v1User!.name, isAdmin: v1User!.isAdmin } satisfies UserInfo), true
      return send(res, 200, { id: signedIn.id, name: signedIn.name, isAdmin: false, login: signedIn.login, avatarURL: signedIn.avatarURL, teams: teamsOf(signedIn) } satisfies UserInfo), true
    }
    if (method === 'GET' && path === '/v1/hosts') {
      return send(res, 200, [...hosts.values()].filter((h) => h.teamID === devTeam.id).map(hostInfo)), true
    }
    if (method === 'POST' && path === '/v1/invites') {
      return send(res, 200, { code: token().slice(0, 8), expiresAt: isoDate(new Date(Date.now() + 7 * 86_400_000)) }), true
    }

    if (signedIn) {
      const user = signedIn
      if (path === '/v1/teams') {
        if (method === 'GET') return send(res, 200, teamsOf(user)), true
        if (method === 'POST') {
          const { name } = await body<{ name: string }>(req)
          if (!name?.trim()) return send(res, 400, { error: true, reason: 'A team needs a name' }), true
          const team: MockTeam = { id: uuid(), name: name.trim(), members: new Map([[user.id, 'owner']]), installations: [] }
          teams.set(team.id, team)
          return send(res, 200, { id: team.id, name: team.name, role: 'owner' } satisfies Team), true
        }
      }
      const accept = path.match(/^\/v1\/invites\/([^/]+)\/accept$/)
      if (method === 'POST' && accept) {
        const invite = invites.get(decodeURIComponent(accept[1]))
        if (!invite || invite.expiresAt < new Date()) return send(res, 404, { error: true, reason: 'Unknown or expired invite' }), true
        invites.delete(decodeURIComponent(accept[1]))
        const team = teams.get(invite.teamID)!
        // Joining again never lowers a role.
        const current = team.members.get(user.id)
        if (!current || rank[current] < rank[invite.role]) team.members.set(user.id, invite.role)
        return send(res, 200, { id: team.id, name: team.name, role: team.members.get(user.id)! } satisfies Team), true
      }
      const sub = path.match(/^\/v1\/teams\/([^/]+)\/(members|invites|host-codes|hosts|github\/link|github)$/)
      if (sub) {
        const [, id, what] = sub
        if (method === 'GET' && what === 'members') {
          const team = teamFor(user, id)
          const members: TeamMember[] = [...team.members].map(([userID, role]) => {
            const u = users.get(userID)!
            return { userID, login: u.login, name: u.name, avatarURL: u.avatarURL, role }
          })
          return send(res, 200, members), true
        }
        if (method === 'GET' && what === 'hosts') {
          const team = teamFor(user, id)
          return send(res, 200, [...hosts.values()].filter((h) => h.teamID === team.id).map(hostInfo)), true
        }
        if (method === 'POST' && what === 'invites') {
          const team = teamFor(user, id, 'admin')
          const { role = 'member' } = await body<{ role?: TeamRole }>(req)
          if (role === 'owner') return send(res, 400, { error: true, reason: 'Owners are not invited' }), true
          const code = token().slice(0, 10)
          const expiresAt = new Date(Date.now() + 7 * 86_400_000)
          invites.set(code, { teamID: team.id, role, expiresAt })
          const scheme = secure ? 'https' : 'http'
          return send(res, 200, { code, expiresAt: isoDate(expiresAt), teamID: team.id, role, url: `${scheme}://${origin}/invite/${code}` }), true
        }
        if (method === 'POST' && what === 'host-codes') {
          const team = teamFor(user, id, 'admin')
          const code = randomBytes(4).toString('hex').toUpperCase()
          const expiresAt = new Date(Date.now() + 15 * 60_000)
          hostCodes.set(code, { teamID: team.id, expiresAt })
          return send(res, 200, { code, expiresAt: isoDate(expiresAt) }), true
        }
        if (method === 'POST' && what === 'github/link') {
          const team = teamFor(user, id, 'admin')
          // Skips GitHub: straight to the setup callback, as if the App had been installed.
          return send(res, 200, { url: `/github/setup?installation_id=1&state=${team.id}` }), true
        }
        if (method === 'GET' && what === 'github') return send(res, 200, teamFor(user, id, 'admin').installations), true
      }
    }

    if (method === 'POST' && path === '/v1/sessions') {
      const request = await body<{ device?: SessionInfo['device']; hostID?: string; teamID?: string }>(req)
      let teamID = devTeam.id
      if (signedIn) {
        const mine = teamsOf(signedIn)
        if (request.teamID) teamID = teamFor(signedIn, request.teamID).id
        else if (mine.length === 1) teamID = mine[0].id
        else return send(res, 400, { error: true, reason: mine.length ? 'teamID is required' : 'Not in a team' }), true
      }
      const now = new Date()
      const s: Session = {
        info: {
          id: uuid(), state: 'queued', device: request.device ?? { deviceType: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-27-2' },
          hostID: request.hostID ?? undefined,
          createdAt: isoDate(now), expiresAt: isoDate(new Date(now.getTime() + 3_600_000)),
          ...(signedIn ? { teamID } : {}),
        },
        tokens: { viewer: token(), host: token() }, sockets: {}, queued: { viewer: [], host: [] }, leased: false,
      }
      sessions.set(s.info.id, s)
      dispatch()
      return send(res, 200, s.info), true
    }
    const one = path.match(/^\/v1\/sessions\/([^/]+)$/)
    if (one) {
      const s = sessions.get(one[1].toUpperCase())
      if (!s || (signedIn && s.info.teamID && !teams.get(s.info.teamID)?.members.has(signedIn.id))) return send(res, 404, { error: true, reason: 'No such session' }), true
      if (method === 'GET') return send(res, 200, s.info), true
      if (method === 'DELETE') return end(s, 'ended', 'ended by the user'), send(res, 204), true
    }
    return false
  }

  return {
    name: 'maccheri-mock-control-plane',
    configureServer(server) {
      if (process.env.VITE_API) return
      server.middlewares.use((req, res, next) => {
        handle(req, res).then((done) => { if (!done) next() }, (e) => {
          if (e instanceof HTTPError) return send(res, e.status, { error: true, reason: e.message })
          console.error(e)
          send(res, 500, { error: true, reason: String(e) })
        })
      })
      const wss = new WebSocketServer({ noServer: true })
      server.httpServer?.on('upgrade', (req, socket, head) => {
        const url = new URL(req.url ?? '/', 'http://x')
        const m = url.pathname.match(/^\/v1\/sessions\/([^/]+)\/signal$/)
        if (!m) return // Vite's own HMR socket
        const s = sessions.get(m[1].toUpperCase())
        const role = url.searchParams.get('role') as SignalingRole
        if (!s || (role !== 'viewer' && role !== 'host') || url.searchParams.get('token') !== s.tokens[role]) {
          socket.end('HTTP/1.1 403 Forbidden\r\n\r\n')
          return
        }
        wss.handleUpgrade(req, socket, head, (ws) => {
          const other: SignalingRole = role === 'viewer' ? 'host' : 'viewer'
          s.sockets[role]?.close()
          s.sockets[role] = ws
          for (const frame of s.queued[role].splice(0)) ws.send(frame)
          ws.on('message', (data) => {
            const frame = data.toString()
            const peer = s.sockets[other]
            if (peer && peer.readyState === peer.OPEN) peer.send(frame)
            else s.queued[other].push(frame)
          })
          ws.on('close', () => { if (s.sockets[role] === ws) delete s.sockets[role] })
        })
      })
    },
  }
}
