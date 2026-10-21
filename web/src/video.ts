// Two ways to show the stream; the session picks one with StreamConfig.
//
// TrackRenderer: the RTP H.264 track in a <video>, jitter buffer target 0 (the host also sends
// playout-delay 0). Per-frame metadata (inputAck) comes as FrameInfo on the control channel and
// is matched by RTP timestamp in requestVideoFrameCallback.
//
// CanvasRenderer: SimStream `video` messages from the data channel, decoded with WebCodecs
// (optimizeForLatency) and drawn into a <canvas> as soon as they are decoded.

import type { FrameInfo, VideoFrame as SimFrame } from './protocol'

export interface Shown {
  inputAck: number
  ackAgeMicros: number
  atMs: number
}

export interface Renderer {
  readonly element: HTMLVideoElement | HTMLCanvasElement
  /** Every displayed frame that carries metadata. */
  onShown: ((frame: Shown) => void) | null
  /** Displayed frames since the last call. */
  takeFrameCount(): number
  /** Decoder trouble; the caller asks for a keyframe. */
  onNeedKeyframe: (() => void) | null
  /** Video size in pixels, once known. */
  onSize: ((width: number, height: number) => void) | null
  close(): void
}

type FrameCallbackMetadata = { rtpTimestamp?: number; presentedFrames: number; width: number; height: number }
type VideoWithFrameCallback = HTMLVideoElement & {
  requestVideoFrameCallback?(cb: (now: number, metadata: FrameCallbackMetadata) => void): number
  cancelVideoFrameCallback?(handle: number): void
}

export class TrackRenderer implements Renderer {
  readonly element: VideoWithFrameCallback = document.createElement('video')
  onShown: ((frame: Shown) => void) | null = null
  onNeedKeyframe: (() => void) | null = null
  onSize: ((width: number, height: number) => void) | null = null
  private infos = new Map<number, FrameInfo>()
  private frames = 0
  private lastPresented = 0
  private handle = 0
  private closed = false

  constructor(readonly receiver: RTCRtpReceiver, stream: MediaStream) {
    const r = receiver as RTCRtpReceiver & { jitterBufferTarget?: number | null; playoutDelayHint?: number }
    // Chrome, Firefox and Safari 18 have jitterBufferTarget (ms); older Chrome had playoutDelayHint (s).
    try { r.jitterBufferTarget = 0 } catch { /* unsupported */ }
    try { r.playoutDelayHint = 0 } catch { /* unsupported */ }
    const v = this.element
    v.muted = true
    v.autoplay = true
    v.playsInline = true
    v.disablePictureInPicture = true
    v.srcObject = stream
    v.addEventListener('resize', () => this.onSize?.(v.videoWidth, v.videoHeight))
    void v.play().catch(() => { /* autoplay of muted video is allowed; retried on the first click */ })
    if (v.requestVideoFrameCallback) this.handle = v.requestVideoFrameCallback((now, m) => this.frame(now, m))
  }

  addInfo(info: FrameInfo) {
    this.infos.set(info.rtpTimestamp, info)
    // RTP timestamps of frames that were never shown pile up; keep the newest few hundred.
    if (this.infos.size > 300) {
      const oldest = this.infos.keys().next().value
      if (oldest !== undefined) this.infos.delete(oldest)
    }
  }

  private frame(_now: number, m: FrameCallbackMetadata) {
    if (this.closed) return
    const atMs = performance.now()
    this.frames += Math.max(1, m.presentedFrames - this.lastPresented)
    this.lastPresented = m.presentedFrames
    if (m.rtpTimestamp !== undefined) {
      const info = this.infos.get(m.rtpTimestamp)
      if (info) {
        this.infos.delete(m.rtpTimestamp)
        this.onShown?.({ inputAck: info.inputAck, ackAgeMicros: info.ackAgeMicros, atMs })
      }
    }
    this.handle = this.element.requestVideoFrameCallback!((now, meta) => this.frame(now, meta))
  }

  takeFrameCount() { const n = this.frames; this.frames = 0; return n }

  close() {
    this.closed = true
    this.element.cancelVideoFrameCallback?.(this.handle)
    this.element.srcObject = null
  }
}

/** avcC (ISO 14496-15) from SPS and PPS, the `description` WebCodecs wants for AVCC input. */
export function avcC(sps: Uint8Array, pps: Uint8Array): Uint8Array {
  const out = new Uint8Array(11 + sps.length + pps.length)
  out.set([1, sps[1], sps[2], sps[3], 0xff, 0xe1, sps.length >> 8, sps.length & 0xff], 0)
  out.set(sps, 8)
  out.set([1, pps.length >> 8, pps.length & 0xff], 8 + sps.length)
  out.set(pps, 11 + sps.length)
  return out
}

/** RFC 6381 codec string, e.g. `avc1.640033`. */
export function codecString(sps: Uint8Array): string {
  return 'avc1.' + [sps[1], sps[2], sps[3]].map((b) => b.toString(16).padStart(2, '0')).join('')
}

export class CanvasRenderer implements Renderer {
  readonly element = document.createElement('canvas')
  onShown: ((frame: Shown) => void) | null = null
  onNeedKeyframe: (() => void) | null = null
  onSize: ((width: number, height: number) => void) | null = null
  private context = this.element.getContext('2d', { alpha: false, desynchronized: true })!
  private decoder: VideoDecoder | null = null
  private configured = ''
  private pending = new Map<number, { inputAck: number; ackAgeMicros: number }>()
  private frames = 0
  /** Delta frames are useless until the next keyframe after an error. */
  private broken = true

  static get supported() { return typeof VideoDecoder !== 'undefined' }

  /** Feed a SimStream video frame, in order. */
  push(f: SimFrame) {
    if (f.isKeyframe && f.parameterSets.length >= 2) this.configure(f.parameterSets[0], f.parameterSets[1])
    if (!this.decoder || this.decoder.state !== 'configured') return this.needKeyframe()
    if (this.broken && !f.isKeyframe) return this.needKeyframe()
    this.broken = false
    // Timestamps only identify the frame in the output callback; they must be unique.
    this.pending.set(f.captureMicros, { inputAck: f.inputAck, ackAgeMicros: f.ackAgeMicros })
    try {
      this.decoder.decode(new EncodedVideoChunk({ type: f.isKeyframe ? 'key' : 'delta', timestamp: f.captureMicros, data: f.payload }))
    } catch (e) {
      console.warn('decode', e)
      this.needKeyframe()
    }
  }

  /** The data channel lost a frame: wait for a keyframe. */
  lost() { this.needKeyframe() }

  private lastRequestMs = -Infinity

  /** Asks again while frames keep coming without a keyframe: the keyframe itself can be lost. */
  private needKeyframe() {
    this.broken = true
    const now = performance.now()
    if (now - this.lastRequestMs < 300) return
    this.lastRequestMs = now
    this.onNeedKeyframe?.()
  }

  private configure(sps: Uint8Array, pps: Uint8Array) {
    const description = avcC(sps, pps)
    const key = Array.from(description).join(',')
    if (key === this.configured && this.decoder?.state === 'configured') return
    this.decoder?.close()
    this.decoder = new VideoDecoder({
      output: (frame) => this.show(frame),
      error: (e) => {
        console.warn('decoder', e)
        this.configured = ''
        this.needKeyframe()
      },
    })
    this.decoder.configure({ codec: codecString(sps), description, optimizeForLatency: true, hardwareAcceleration: 'no-preference' })
    this.configured = key
    this.broken = false
  }

  private show(frame: globalThis.VideoFrame) {
    const c = this.element
    if (c.width !== frame.displayWidth || c.height !== frame.displayHeight) {
      c.width = frame.displayWidth
      c.height = frame.displayHeight
      this.onSize?.(c.width, c.height)
    }
    this.context.drawImage(frame, 0, 0)
    const meta = this.pending.get(frame.timestamp)
    this.pending.delete(frame.timestamp)
    frame.close()
    this.frames++
    // Stamped at the next animation frame, when the drawing goes to the screen: the same moment
    // requestVideoFrameCallback reports for <video>, so both renderers are measured alike.
    if (meta) requestAnimationFrame(() => this.onShown?.({ ...meta, atMs: performance.now() }))
    if (this.pending.size > 100) this.pending.clear()
  }

  takeFrameCount() { const n = this.frames; this.frames = 0; return n }

  close() {
    if (this.decoder && this.decoder.state !== 'closed') this.decoder.close()
    this.decoder = null
  }
}
