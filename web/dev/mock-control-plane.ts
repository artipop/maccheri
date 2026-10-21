// A stand-in control plane inside the Vite dev server, so the web client and the host peer can be
// developed without the real one. In-memory, single team, any invite code works.
//
//   npm run dev                      # web client + mock on :5173
//   simstream-peer --guest 127.0.0.1:7300 --control-plane http://localhost:5173
//
// Implements the parts of protocol/Sources/MaccheriProtocol the client and the agent use:
// /v1/auth/redeem, /v1/me, /v1/hosts, /v1/sessions, the signaling WebSocket, /agent/v1/work and
// /agent/v1/sessions/{id}/state. MOCK_ICE="stun:…,turn:user:pass@…" adds ICE servers.
// With VITE_API pointing elsewhere (a real control plane) the mock stays off.

import { randomBytes, randomUUID } from 'node:crypto'
import type { IncomingMessage, ServerResponse } from 'node:http'
import type { Plugin } from 'vite'
import { WebSocketServer, type WebSocket } from 'ws'
import type { HostInfo, ICEServer, SessionInfo, SignalingRole, UserInfo } from '../src/api.ts'

const uuid = () => randomUUID().toUpperCase()
const token = () => randomBytes(18).toString('base64url')
// Swift's .iso8601 strategy rejects fractional seconds.
const isoDate = (d: Date) => d.toISOString().replace(/\.\d{3}Z$/, 'Z')

interface Session {
  info: SessionInfo
  tokens: Record<SignalingRole, string>
  sockets: Partial<Record<SignalingRole, WebSocket>>
  /** Frames for a side that hasn't joined yet. */
  queued: Record<SignalingRole, string[]>
  leased: boolean
}

export function mockControlPlane(): Plugin {
  const users = new Map<string, UserInfo>()
  const sessions = new Map<string, Session>()
  const waiting: { res: ServerResponse; host: string; timer: NodeJS.Timeout }[] = []
  const hostID = uuid()
  let agentSeen = 0

  const iceServers = (): ICEServer[] =>
    (process.env.MOCK_ICE ?? '').split(',').filter(Boolean).map((url) => {
      const m = url.match(/^(turns?):([^:]*):([^@]*)@(.*)$/)
      return m ? { urls: [`${m[1]}:${m[4]}`], username: decodeURIComponent(m[2]), credential: decodeURIComponent(m[3]) } : { urls: [url] }
    })

  const secure = !!process.env.DEV_HTTPS_CERT
  const signaling = (s: Session, role: SignalingRole, host: string) => ({
    url: `${secure ? 'wss' : 'ws'}://${host}/v1/sessions/${s.info.id}/signal?role=${role}&token=${s.tokens[role]}`,
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

  // MOCK_SHARED_TOKEN (default `dev`) is the team's shared secret, as MACCHERI_SHARED_TOKEN on the real one.
  const sharedToken = process.env.MOCK_SHARED_TOKEN ?? 'dev'
  const agentTokens = new Set<string>()
  const user = (req: IncomingMessage) => {
    const bearer = (req.headers.authorization ?? '').replace(/^Bearer /, '')
    return bearer === sharedToken ? { id: hostID, name: 'team', isAdmin: true } : users.get(bearer)
  }

  /** Hands a queued session to a waiting agent, if both exist. */
  function dispatch() {
    for (const s of sessions.values()) {
      if (s.leased || s.info.state !== 'queued') continue
      const agent = waiting.shift()
      if (!agent) return
      clearTimeout(agent.timer)
      s.leased = true
      s.info.state = 'starting'
      s.info.hostID = hostID
      s.info.hostName = 'Dev Mac'
      s.info.signaling = signaling(s, 'viewer', agent.host)
      send(agent.res, 200, { simulator: { _0: {
        sessionID: s.info.id, image: 'macos-27-xcode-27.2', device: s.info.device,
        timeoutSeconds: 3600, signaling: signaling(s, 'host', agent.host),
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

  async function handle(req: IncomingMessage, res: ServerResponse): Promise<boolean> {
    const url = new URL(req.url ?? '/', 'http://x')
    const path = url.pathname
    const method = req.method ?? 'GET'
    const host = req.headers.host ?? 'localhost:5173'

    if (method === 'POST' && path === '/v1/auth/redeem') {
      const { name } = await body<{ code: string; name: string }>(req)
      const t = token()
      const info = { id: uuid(), name: name || 'Dev', isAdmin: users.size === 0 }
      users.set(t, info)
      send(res, 200, { userID: info.id, token: t })
      return true
    }
    if (path.startsWith('/agent/v1/')) {
      // Any agent token works; the dev host is online while it polls.
      agentSeen = Date.now()
      if (method === 'POST' && path === '/agent/v1/work') {
        await body(req)
        const entry = { res, host, timer: setTimeout(() => { waiting.splice(waiting.indexOf(entry), 1); send(res, 204) }, 25_000) }
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
      if (!user(req)) return send(res, 401, { error: true, reason: 'Unauthorized' }), true
      await body(req)
      const agentToken = token()
      agentTokens.add(agentToken)
      return send(res, 200, { hostID, agentToken }), true
    }

    const me = user(req)
    if (!me) return send(res, 401, { error: true, reason: 'Unauthorized' }), true

    if (method === 'GET' && path === '/v1/me') return send(res, 200, me), true
    if (method === 'POST' && path === '/v1/invites') {
      return send(res, 200, { code: token().slice(0, 8), expiresAt: isoDate(new Date(Date.now() + 7 * 86_400_000)) }), true
    }
    if (method === 'GET' && path === '/v1/hosts') {
      const online = Date.now() - agentSeen < 45_000
      const hosts: HostInfo[] = [{
        id: hostID, name: 'Dev Mac', ownerName: 'dev',
        hardware: { model: 'Mac16,10', chip: 'Apple M4', cpuCount: 10, memoryBytes: 16 * 2 ** 30, macOSVersion: '27.0.1' },
        online,
        capacity: { freeSlots: 1, warmVMs: 1, images: ['macos-27-xcode-27.2'], labels: ['maccheri'], devices: [{ deviceType: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-27-2' }] },
      }]
      return send(res, 200, hosts), true
    }
    if (method === 'POST' && path === '/v1/sessions') {
      const request = await body<{ device?: SessionInfo['device'] }>(req)
      const now = new Date()
      const s: Session = {
        info: {
          id: uuid(), state: 'queued', device: request.device ?? { deviceType: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-27-2' },
          createdAt: isoDate(now), expiresAt: isoDate(new Date(now.getTime() + 3_600_000)),
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
      if (!s) return send(res, 404, { error: true, reason: 'No such session' }), true
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
        handle(req, res).then((done) => { if (!done) next() }, (e) => { console.error(e); send(res, 500, { error: true, reason: String(e) }) })
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
