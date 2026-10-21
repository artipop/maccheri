// One remote simulator session in the browser: signaling as the viewer, the WebRTC answer, the
// host peer's channels, input out, video in, stats.

import type { SignalingInfo, SignalMessage } from './api'
import { decode, encode, FrameAssembler, type Button, type Hello, type InstallState, type Message, type Orientation, type TouchPhase, type VideoTransport } from './protocol'
import { LatencyTracker } from './latency'
import { CanvasRenderer, TrackRenderer, type Renderer } from './video'

export interface Stats {
  /** 'direct' (host or srflx on both ends), 'relay' (TURN) or null while connecting. */
  path: 'direct' | 'relay' | null
  /** e.g. "host ⇄ srflx, udp". */
  pathDetail: string
  /** ICE round trip, ms. */
  rttMs: number | null
  /** Ping through the host to simstream and back, ms. */
  pingMs: number | null
  fps: number
  mbps: number
  lastClickMs: number | null
  clickP50Ms: number | null
  clickP95Ms: number | null
  serverP50Ms: number | null
  clicks: number
  lostFrames: number
  transport: VideoTransport
}

export type SessionState = 'connecting' | 'connected' | 'reconnecting' | 'ended'

export interface SessionEvents {
  onState(state: SessionState, detail?: string): void
  onHello(hello: Hello): void
  onRenderer(renderer: Renderer): void
  onStats(stats: Stats): void
  onInstall(state: InstallState, message: string): void
}

export class SimSession {
  private ws: WebSocket | null = null
  private pc: RTCPeerConnection
  private control: RTCDataChannel | null = null
  private renderer: Renderer | null = null
  private assembler = new FrameAssembler()
  private tracker = new LatencyTracker()
  private nextTouchID = 1
  private timer = 0
  private lastBytes = 0
  private lastStatsMs = performance.now()
  private pingMs: number | null = null
  private ended = false
  private pendingCandidates: RTCIceCandidateInit[] = []
  hello: Hello | null = null
  /** What happened, for debugging (`maccheri.session.log` in the console). */
  readonly log: string[] = []

  private note(line: string) {
    this.log.push(`${(performance.now() / 1000).toFixed(2)} ${line}`)
    if (this.log.length > 500) this.log.shift()
  }

  /** `relayOnly` forces TURN (testing the relay path). */
  constructor(private signaling: SignalingInfo, readonly transport: VideoTransport, private events: SessionEvents, relayOnly = false) {
    this.pc = new RTCPeerConnection({
      iceServers: signaling.iceServers.map((s) => ({ urls: s.urls, username: s.username ?? undefined, credential: s.credential ?? undefined })),
      iceTransportPolicy: relayOnly ? 'relay' : 'all',
    })
  }

  start() {
    const pc = this.pc
    pc.onicecandidate = (e) => {
      if (e.candidate) this.signal({ candidate: { candidate: e.candidate.candidate, sdpMid: e.candidate.sdpMid, sdpMLineIndex: e.candidate.sdpMLineIndex } })
    }
    pc.oniceconnectionstatechange = () => this.note(`ice ${pc.iceConnectionState}`)
    pc.onicecandidateerror = (e) => this.note(`candidate error ${(e as RTCPeerConnectionIceErrorEvent).errorCode} ${(e as RTCPeerConnectionIceErrorEvent).errorText} ${(e as RTCPeerConnectionIceErrorEvent).url}`)
    pc.onconnectionstatechange = () => {
      this.note(`connection ${pc.connectionState}`)
      switch (pc.connectionState) {
        case 'connected': this.events.onState('connected'); break
        case 'disconnected': this.events.onState('reconnecting'); break
        case 'failed': this.end('connection failed'); break
        case 'closed': this.end('connection closed'); break
      }
    }
    pc.ondatachannel = (e) => this.channel(e.channel)
    pc.ontrack = (e) => {
      if (this.transport !== 'track' || e.track.kind !== 'video') return
      const renderer = new TrackRenderer(e.receiver, e.streams[0] ?? new MediaStream([e.track]))
      this.useRenderer(renderer)
    }
    if (this.transport === 'dataChannel') this.useRenderer(new CanvasRenderer())

    const ws = new WebSocket(this.signaling.url)
    this.ws = ws
    ws.onmessage = (e) => void this.onSignal(JSON.parse(e.data as string) as SignalMessage)
    ws.onclose = () => {
      this.ws = null
      // Once connected the session goes on without signaling; before that it can't.
      if (pc.connectionState !== 'connected') this.end('signaling closed')
    }
    this.events.onState('connecting')
    this.timer = window.setInterval(() => void this.collectStats(), 500)
  }

  private useRenderer(renderer: Renderer) {
    this.renderer?.close()
    this.renderer = renderer
    renderer.onShown = (f) => this.tracker.frame(f.inputAck, f.ackAgeMicros, f.atMs)
    renderer.onNeedKeyframe = () => this.send({ type: 'requestKeyframe' })
    this.events.onRenderer(renderer)
  }

  private async onSignal(m: SignalMessage) {
    const pc = this.pc
    this.note(`signal in ${Object.keys(m)[0]}${'candidate' in m ? ` ${m.candidate.candidate}` : ''}`)
    try {
      if ('offer' in m) {
        await pc.setRemoteDescription({ type: 'offer', sdp: m.offer.sdp })
        const answer = await pc.createAnswer()
        await pc.setLocalDescription(answer)
        this.signal({ answer: { sdp: pc.localDescription!.sdp } })
        for (const c of this.pendingCandidates.splice(0)) await pc.addIceCandidate(c)
      } else if ('candidate' in m) {
        const c: RTCIceCandidateInit = { candidate: m.candidate.candidate, sdpMid: m.candidate.sdpMid ?? undefined, sdpMLineIndex: m.candidate.sdpMLineIndex ?? undefined }
        // libdatachannel names only the mid; browsers want one of the two.
        if (c.sdpMid === undefined && c.sdpMLineIndex === undefined) c.sdpMLineIndex = 0
        if (pc.remoteDescription) await pc.addIceCandidate(c)
        else this.pendingCandidates.push(c)
      } else if ('bye' in m) {
        this.end(m.bye.reason ?? 'the host ended the session', false)
      }
    } catch (e) {
      console.warn('signaling', m, e)
      this.note(`signal error ${e}`)
    }
  }

  private signal(m: SignalMessage) {
    this.note(`signal out ${Object.keys(m)[0]}${'candidate' in m ? ` ${m.candidate.candidate}` : ''}`)
    if (this.ws?.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify(m))
    else this.ws?.addEventListener('open', () => this.ws?.send(JSON.stringify(m)), { once: true })
  }

  private channel(dc: RTCDataChannel) {
    dc.binaryType = 'arraybuffer'
    if (dc.label === 'control') {
      this.control = dc
      dc.onopen = () => this.send({ type: 'streamConfig', video: this.transport })
      dc.onmessage = (e) => this.onControl(decode(new Uint8Array(e.data as ArrayBuffer)))
      dc.onclose = () => this.end('the host closed the session')
    } else if (dc.label === 'video') {
      dc.onmessage = (e) => this.onVideo(decode(new Uint8Array(e.data as ArrayBuffer)))
    }
  }

  private onControl(m: Message) {
    switch (m.type) {
      case 'hello': this.hello = m.hello; this.events.onHello(m.hello); break
      case 'frameInfo': if (this.renderer instanceof TrackRenderer) this.renderer.addInfo(m.info); break
      case 'pong': this.pingMs = performance.now() - Number(m.value) / 1000; break
      case 'installStatus': this.events.onInstall(m.state, m.message); break
      default: break
    }
  }

  private onVideo(m: Message) {
    if (m.type !== 'videoChunk' || !(this.renderer instanceof CanvasRenderer)) return
    const { body, lost } = this.assembler.push(m.chunk)
    if (lost) this.renderer.lost()
    if (!body) return
    const frame = decode(body)
    if (frame.type === 'video') this.renderer.push(frame.frame)
  }

  send(m: Message) {
    if (this.control?.readyState === 'open') this.control.send(encode(m) as Uint8Array<ArrayBuffer>)
  }

  /** x, y normalised to the screen, 0…1 from the top-left. */
  touch(phase: TouchPhase, x: number, y: number) {
    const id = this.nextTouchID++
    this.tracker.sent(id, phase, performance.now())
    this.send({ type: 'touch', id, phase, x: Math.min(Math.max(x, 0), 1), y: Math.min(Math.max(y, 0), 1) })
  }

  key(usage: number, down: boolean) { this.send({ type: 'key', usage, down }) }

  press(button: Button) {
    this.send({ type: 'button', button, down: true })
    this.send({ type: 'button', button, down: false })
  }

  rotate(orientation: Orientation) { this.send({ type: 'orientation', orientation }) }

  /** Sends a zipped .app over `control`, keeping the channel's buffer short so input isn't stuck behind it. */
  async install(file: File, onProgress: (fraction: number) => void) {
    const dc = this.control
    if (!dc || dc.readyState !== 'open') throw new Error('not connected')
    this.send({ type: 'installBegin', name: file.name, size: file.size })
    const chunkSize = 16 * 1024 - 8
    dc.bufferedAmountLowThreshold = 256 * 1024
    for (let offset = 0; offset < file.size; offset += chunkSize) {
      if (dc.bufferedAmount > 1024 * 1024) {
        await new Promise<void>((resolve) => dc.addEventListener('bufferedamountlow', () => resolve(), { once: true }))
      }
      if (dc.readyState !== 'open') throw new Error('connection lost during upload')
      const data = new Uint8Array(await file.slice(offset, offset + chunkSize).arrayBuffer())
      this.send({ type: 'installChunk', data })
      onProgress(Math.min(1, (offset + data.length) / file.size))
    }
    this.send({ type: 'installEnd' })
  }

  private async collectStats() {
    const now = performance.now()
    this.send({ type: 'ping', value: BigInt(Math.round(now * 1000)) })
    const report = await this.pc.getStats()
    let pair: RTCIceCandidatePairStats | undefined
    let bytes = 0
    report.forEach((s) => {
      if (s.type === 'transport' && (s as RTCTransportStats).selectedCandidatePairId) {
        pair = report.get((s as RTCTransportStats).selectedCandidatePairId!) as RTCIceCandidatePairStats
      }
      if (s.type === 'transport') bytes += (s as RTCTransportStats).bytesReceived ?? 0
    })
    // Firefox has no selectedCandidatePairId; it marks the pair instead.
    if (!pair) report.forEach((s) => { if (s.type === 'candidate-pair' && ((s as { selected?: boolean }).selected || (s as RTCIceCandidatePairStats).nominated && s.state === 'succeeded')) pair ??= s as RTCIceCandidatePairStats })
    if (bytes === 0) report.forEach((s) => { if (s.type === 'candidate-pair' && s === pair) bytes = (s as RTCIceCandidatePairStats).bytesReceived ?? 0 })
    let path: Stats['path'] = null
    let pathDetail = ''
    if (pair) {
      const local = report.get(pair.localCandidateId) as { candidateType?: string; protocol?: string; relayProtocol?: string } | undefined
      const remote = report.get(pair.remoteCandidateId) as { candidateType?: string } | undefined
      path = local?.candidateType === 'relay' || remote?.candidateType === 'relay' ? 'relay' : 'direct'
      pathDetail = `${local?.candidateType ?? '?'} ⇄ ${remote?.candidateType ?? '?'}, ${local?.protocol ?? '?'}${local?.relayProtocol ? ` via ${local.relayProtocol}` : ''}`
    }
    const seconds = (now - this.lastStatsMs) / 1000
    const frames = this.renderer?.takeFrameCount() ?? 0
    const mbps = bytes >= this.lastBytes ? ((bytes - this.lastBytes) * 8) / seconds / 1e6 : 0
    this.lastBytes = bytes
    this.lastStatsMs = now
    const server = [...this.tracker.serverSamples].sort((a, b) => a - b)
    this.events.onStats({
      path, pathDetail,
      rttMs: pair?.currentRoundTripTime !== undefined ? pair.currentRoundTripTime * 1000 : null,
      pingMs: this.pingMs,
      fps: frames / seconds,
      mbps,
      lastClickMs: this.tracker.last,
      clickP50Ms: this.tracker.percentile(0.5),
      clickP95Ms: this.tracker.percentile(0.95),
      serverP50Ms: server.length ? server[Math.floor(server.length / 2)] : null,
      clicks: this.tracker.samples.length,
      lostFrames: this.assembler.lost,
      transport: this.transport,
    })
  }

  /** Every click → frame sample so far, ms. */
  get samples() { return [...this.tracker.samples] }

  /** Tears down; tells the host unless it was the host that said bye. */
  end(reason: string, tellHost = true) {
    if (this.ended) return
    this.ended = true
    if (tellHost && this.ws?.readyState === WebSocket.OPEN) this.ws.send(JSON.stringify({ bye: { reason } } satisfies SignalMessage))
    window.clearInterval(this.timer)
    this.renderer?.close()
    this.control?.close()
    this.pc.close()
    this.ws?.close()
    this.events.onState('ended', reason)
  }
}
