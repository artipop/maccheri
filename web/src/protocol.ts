// SimStream messages as they travel over the data channels: one message per data channel message,
// type byte + payload, without the TCP length prefix. Mirrors
// protocol/Sources/SimStreamProtocol/SimStream.swift; integers are big-endian.

export const enum MessageType {
  Hello = 1,
  Video = 2,
  Touch = 3,
  RequestKeyframe = 4,
  Ping = 5,
  Pong = 6,
  Key = 7,
  Button = 8,
  Orientation = 9,
  InstallBegin = 10,
  InstallChunk = 11,
  InstallEnd = 12,
  InstallStatus = 13,
  StreamConfig = 14,
  FrameInfo = 15,
  VideoChunk = 16,
}

export type TouchPhase = 'began' | 'moved' | 'ended'
const touchPhases: TouchPhase[] = ['began', 'moved', 'ended']

export type Button = 'home' | 'lock' | 'siri' | 'volumeUp' | 'volumeDown'
const buttons: Button[] = ['home', 'lock', 'siri', 'volumeUp', 'volumeDown']

/** UIDeviceOrientation values. */
export type Orientation = 'portrait' | 'portraitUpsideDown' | 'landscapeLeft' | 'landscapeRight'
const orientations: Orientation[] = ['portrait', 'portraitUpsideDown', 'landscapeLeft', 'landscapeRight']

export type InstallState = 'receiving' | 'installing' | 'launched' | 'failed'
const installStates: InstallState[] = ['receiving', 'installing', 'launched', 'failed']

export type VideoTransport = 'track' | 'dataChannel'
const videoTransports: VideoTransport[] = ['track', 'dataChannel']

export interface Hello {
  version: number
  screenWidth: number
  screenHeight: number
  videoWidth: number
  videoHeight: number
  codec: number
  deviceID: string
  deviceName: string
}

export interface VideoFrame {
  isKeyframe: boolean
  inputAck: number
  ackAgeMicros: number
  encodeMicros: number
  /** Server µs; a bigint would be exact, but 2^53 µs is 285 years of uptime. */
  captureMicros: number
  parameterSets: Uint8Array[]
  /** AVCC: NAL units with 4-byte length prefixes. */
  payload: Uint8Array
}

export interface FrameInfo {
  rtpTimestamp: number
  isKeyframe: boolean
  inputAck: number
  ackAgeMicros: number
  encodeMicros: number
}

export interface VideoChunk {
  frame: number
  index: number
  count: number
  bytes: Uint8Array
}

export type Message =
  | { type: 'hello'; hello: Hello }
  | { type: 'video'; frame: VideoFrame }
  | { type: 'touch'; id: number; phase: TouchPhase; x: number; y: number }
  | { type: 'requestKeyframe' }
  | { type: 'ping'; value: bigint }
  | { type: 'pong'; value: bigint }
  | { type: 'key'; usage: number; down: boolean }
  | { type: 'button'; button: Button; down: boolean }
  | { type: 'orientation'; orientation: Orientation }
  | { type: 'installBegin'; name: string; size: number }
  | { type: 'installChunk'; data: Uint8Array }
  | { type: 'installEnd' }
  | { type: 'installStatus'; state: InstallState; message: string }
  | { type: 'streamConfig'; video: VideoTransport }
  | { type: 'frameInfo'; info: FrameInfo }
  | { type: 'videoChunk'; chunk: VideoChunk }

export class ProtocolError extends Error {}

class Writer {
  private buffer = new Uint8Array(64)
  private view = new DataView(this.buffer.buffer)
  length = 0

  private reserve(n: number) {
    if (this.length + n <= this.buffer.length) return
    let size = this.buffer.length * 2
    while (size < this.length + n) size *= 2
    const next = new Uint8Array(size)
    next.set(this.buffer.subarray(0, this.length))
    this.buffer = next
    this.view = new DataView(next.buffer)
  }

  u8(v: number) { this.reserve(1); this.view.setUint8(this.length, v); this.length += 1 }
  u16(v: number) { this.reserve(2); this.view.setUint16(this.length, v); this.length += 2 }
  u32(v: number) { this.reserve(4); this.view.setUint32(this.length, v >>> 0); this.length += 4 }
  u64(v: bigint) { this.reserve(8); this.view.setBigUint64(this.length, v); this.length += 8 }
  bytes(v: Uint8Array) { this.reserve(v.length); this.buffer.set(v, this.length); this.length += v.length }
  blob(v: Uint8Array) { this.u16(Math.min(v.length, 0xffff)); this.bytes(v.subarray(0, 0xffff)) }
  string(v: string) { this.blob(new TextEncoder().encode(v)) }
  result(): Uint8Array { return this.buffer.slice(0, this.length) }
}

class Reader {
  private offset = 0
  private view: DataView

  constructor(private data: Uint8Array) {
    this.view = new DataView(data.buffer, data.byteOffset, data.byteLength)
  }

  get atEnd() { return this.offset === this.data.length }

  private need(n: number) {
    if (this.data.length - this.offset < n) throw new ProtocolError('truncated')
  }

  u8() { this.need(1); return this.view.getUint8(this.offset++) }
  u16() { this.need(2); const v = this.view.getUint16(this.offset); this.offset += 2; return v }
  u32() { this.need(4); const v = this.view.getUint32(this.offset); this.offset += 4; return v }
  u64() { this.need(8); const v = this.view.getBigUint64(this.offset); this.offset += 8; return v }
  take(n: number) { this.need(n); const v = this.data.subarray(this.offset, this.offset + n); this.offset += n; return v }
  blob() { return this.take(this.u16()) }
  string() { return new TextDecoder('utf-8', { fatal: true }).decode(this.blob()) }
  rest() { const v = this.data.subarray(this.offset); this.offset = this.data.length; return v }
}

function lookup<T>(table: T[], raw: number, what: string): T {
  const value = table[raw]
  if (value === undefined) throw new ProtocolError(`bad ${what} ${raw}`)
  return value
}

export function encode(m: Message): Uint8Array {
  const w = new Writer()
  switch (m.type) {
    case 'hello': {
      const h = m.hello
      w.u8(MessageType.Hello); w.u16(h.version); w.u32(h.screenWidth); w.u32(h.screenHeight)
      w.u32(h.videoWidth); w.u32(h.videoHeight); w.u32(h.codec); w.string(h.deviceID); w.string(h.deviceName)
      break
    }
    case 'video': {
      const v = m.frame
      w.u8(MessageType.Video); w.u8(v.isKeyframe ? 1 : 0); w.u32(v.inputAck); w.u32(v.ackAgeMicros)
      w.u32(v.encodeMicros); w.u64(BigInt(v.captureMicros)); w.u8(v.parameterSets.length)
      for (const set of v.parameterSets) w.blob(set)
      w.bytes(v.payload)
      break
    }
    case 'touch': {
      w.u8(MessageType.Touch); w.u32(m.id); w.u8(touchPhases.indexOf(m.phase))
      const f = new DataView(new ArrayBuffer(8))
      f.setFloat32(0, m.x); f.setFloat32(4, m.y)
      w.u32(f.getUint32(0)); w.u32(f.getUint32(4))
      break
    }
    case 'requestKeyframe': w.u8(MessageType.RequestKeyframe); break
    case 'ping': w.u8(MessageType.Ping); w.u64(m.value); break
    case 'pong': w.u8(MessageType.Pong); w.u64(m.value); break
    case 'key': w.u8(MessageType.Key); w.u16(m.usage); w.u8(m.down ? 1 : 0); break
    case 'button': w.u8(MessageType.Button); w.u8(buttons.indexOf(m.button)); w.u8(m.down ? 1 : 0); break
    case 'orientation': w.u8(MessageType.Orientation); w.u8(orientations.indexOf(m.orientation) + 1); break
    case 'installBegin': w.u8(MessageType.InstallBegin); w.string(m.name); w.u64(BigInt(m.size)); break
    case 'installChunk': w.u8(MessageType.InstallChunk); w.bytes(m.data); break
    case 'installEnd': w.u8(MessageType.InstallEnd); break
    case 'installStatus': w.u8(MessageType.InstallStatus); w.u8(installStates.indexOf(m.state)); w.string(m.message); break
    case 'streamConfig': w.u8(MessageType.StreamConfig); w.u8(videoTransports.indexOf(m.video)); break
    case 'frameInfo': {
      const f = m.info
      w.u8(MessageType.FrameInfo); w.u32(f.rtpTimestamp); w.u8(f.isKeyframe ? 1 : 0); w.u32(f.inputAck)
      w.u32(f.ackAgeMicros); w.u32(f.encodeMicros)
      break
    }
    case 'videoChunk': {
      const c = m.chunk
      w.u8(MessageType.VideoChunk); w.u32(c.frame); w.u16(c.index); w.u16(c.count); w.bytes(c.bytes)
      break
    }
  }
  return w.result()
}

export function decode(data: Uint8Array): Message {
  const r = new Reader(data)
  const type = r.u8()
  let m: Message
  switch (type) {
    case MessageType.Hello:
      m = { type: 'hello', hello: {
        version: r.u16(), screenWidth: r.u32(), screenHeight: r.u32(), videoWidth: r.u32(), videoHeight: r.u32(),
        codec: r.u32(), deviceID: r.string(), deviceName: r.string(),
      } }
      break
    case MessageType.Video: {
      const isKeyframe = (r.u8() & 1) !== 0
      const inputAck = r.u32(), ackAgeMicros = r.u32(), encodeMicros = r.u32(), captureMicros = Number(r.u64())
      const parameterSets: Uint8Array[] = []
      for (let n = r.u8(); n > 0; n--) parameterSets.push(r.blob())
      m = { type: 'video', frame: { isKeyframe, inputAck, ackAgeMicros, encodeMicros, captureMicros, parameterSets, payload: r.rest() } }
      break
    }
    case MessageType.Touch: {
      const id = r.u32(), phase = lookup(touchPhases, r.u8(), 'touch phase')
      const f = new DataView(new ArrayBuffer(8))
      f.setUint32(0, r.u32()); f.setUint32(4, r.u32())
      m = { type: 'touch', id, phase, x: f.getFloat32(0), y: f.getFloat32(4) }
      break
    }
    case MessageType.RequestKeyframe: m = { type: 'requestKeyframe' }; break
    case MessageType.Ping: m = { type: 'ping', value: r.u64() }; break
    case MessageType.Pong: m = { type: 'pong', value: r.u64() }; break
    case MessageType.Key: m = { type: 'key', usage: r.u16(), down: r.u8() !== 0 }; break
    case MessageType.Button: m = { type: 'button', button: lookup(buttons, r.u8(), 'button'), down: r.u8() !== 0 }; break
    case MessageType.Orientation: m = { type: 'orientation', orientation: lookup(orientations, r.u8() - 1, 'orientation') }; break
    case MessageType.InstallBegin: m = { type: 'installBegin', name: r.string(), size: Number(r.u64()) }; break
    case MessageType.InstallChunk: m = { type: 'installChunk', data: r.rest() }; break
    case MessageType.InstallEnd: m = { type: 'installEnd' }; break
    case MessageType.InstallStatus: m = { type: 'installStatus', state: lookup(installStates, r.u8(), 'install state'), message: r.string() }; break
    case MessageType.StreamConfig: m = { type: 'streamConfig', video: lookup(videoTransports, r.u8(), 'video transport') }; break
    case MessageType.FrameInfo:
      m = { type: 'frameInfo', info: {
        rtpTimestamp: r.u32(), isKeyframe: (r.u8() & 1) !== 0, inputAck: r.u32(), ackAgeMicros: r.u32(), encodeMicros: r.u32(),
      } }
      break
    case MessageType.VideoChunk:
      m = { type: 'videoChunk', chunk: { frame: r.u32(), index: r.u16(), count: r.u16(), bytes: r.rest() } }
      break
    default:
      throw new ProtocolError(`unknown type ${type}`)
  }
  if (!r.atEnd) throw new ProtocolError(`trailing bytes in ${m.type}`)
  return m
}

/**
 * Puts `video` messages back together from the data channel's chunks. Chunks arrive in order (the
 * channel is ordered) but may be missing (it gives up retransmitting after a while). A frame with a
 * hole, or a frame that never showed up at all, counts as lost; the caller then asks for a keyframe.
 */
export class FrameAssembler {
  private frame = -1
  /** Chunks of the current frame; null once it is complete or broken. */
  private parts: Uint8Array[] | null = null
  private expected = 0
  lost = 0

  push(c: VideoChunk): { body?: Uint8Array; lost: boolean } {
    let lost = false
    if (c.frame !== this.frame) {
      const incomplete = this.parts !== null && this.parts.length > 0
      const skipped = this.frame >= 0 && c.frame !== ((this.frame + 1) >>> 0)
      lost = incomplete || skipped
      this.frame = c.frame
      this.parts = []
      this.expected = c.count
    }
    if (this.parts === null) return { lost: this.count(lost) }
    if (c.index !== this.parts.length) {
      this.parts = null
      return { lost: this.count(true) }
    }
    this.parts.push(c.bytes)
    if (this.parts.length < this.expected) return { lost: this.count(lost) }
    const body = new Uint8Array(this.parts.reduce((n, p) => n + p.length, 0))
    let offset = 0
    for (const p of this.parts) { body.set(p, offset); offset += p.length }
    this.parts = null
    return { body, lost: this.count(lost) }
  }

  private count(lost: boolean) {
    if (lost) this.lost++
    return lost
  }
}
