import { describe, expect, test } from 'vitest'
import { decode, encode, FrameAssembler, type Message } from '../src/protocol'

const samples: Message[] = [
  { type: 'hello', hello: { version: 2, screenWidth: 1206, screenHeight: 2622, videoWidth: 603, videoHeight: 1311, codec: 0x61766331, deviceID: '1856F703-8191-4583-9C4C-E646B81F46BE', deviceName: 'iPhone 17 Pro · пробник' } },
  { type: 'video', frame: { isKeyframe: true, inputAck: 7, ackAgeMicros: 12345, encodeMicros: 6000, captureMicros: 2 ** 40, parameterSets: [new Uint8Array([0x67, 0x64, 0, 0x1f]), new Uint8Array([0x68, 0xee])], payload: new Uint8Array(1000).map((_, i) => i & 0xff) } },
  { type: 'video', frame: { isKeyframe: false, inputAck: 0, ackAgeMicros: 0, encodeMicros: 0, captureMicros: 0, parameterSets: [], payload: new Uint8Array() } },
  { type: 'touch', id: 1, phase: 'began', x: 0.25, y: 0.75 },
  { type: 'touch', id: 0xffffffff, phase: 'moved', x: 0, y: 1 },
  { type: 'requestKeyframe' },
  { type: 'ping', value: 0xdeadbeefcafen },
  { type: 'pong', value: 42n },
  { type: 'key', usage: 0x04, down: true },
  { type: 'button', button: 'lock', down: false },
  { type: 'orientation', orientation: 'landscapeLeft' },
  { type: 'installBegin', name: 'Probe.app.zip', size: 12345678 },
  { type: 'installChunk', data: new Uint8Array(300).fill(0xab) },
  { type: 'installEnd' },
  { type: 'installStatus', state: 'failed', message: 'simctl install: exit 1' },
  { type: 'streamConfig', video: 'dataChannel' },
  { type: 'frameInfo', info: { rtpTimestamp: 0xfffffff0, isKeyframe: true, inputAck: 12, ackAgeMicros: 18000, encodeMicros: 6500 } },
  { type: 'videoChunk', chunk: { frame: 9, index: 2, count: 3, bytes: new Uint8Array([1, 2, 3]) } },
]

describe('SimStream messages', () => {
  test.each(samples.map((m) => [m.type, m] as const))('%s round-trips', (_, m) => {
    expect(decode(encode(m))).toEqual(m)
  })

  // Same bytes as protocol/Tests/SimStreamProtocolTests (wireLayoutOfTouch), without the length prefix.
  test('touch has the Swift wire layout', () => {
    expect([...encode({ type: 'touch', id: 0x01020304, phase: 'ended', x: 1, y: 0 })])
      .toEqual([3, 1, 2, 3, 4, 2, 0x3f, 0x80, 0, 0, 0, 0, 0, 0])
  })

  test('orientation uses UIDeviceOrientation values', () => {
    expect([...encode({ type: 'orientation', orientation: 'portrait' })]).toEqual([9, 1])
    expect([...encode({ type: 'orientation', orientation: 'landscapeRight' })]).toEqual([9, 4])
  })

  test('rejects garbage', () => {
    expect(() => decode(new Uint8Array([99]))).toThrow('unknown type')
    expect(() => decode(new Uint8Array([3, 0, 0]))).toThrow('truncated')
    expect(() => decode(new Uint8Array([4, 0]))).toThrow('trailing')
    expect(() => decode(new Uint8Array([8, 9, 1]))).toThrow('bad button')
  })
})

describe('FrameAssembler', () => {
  const chunks = (frame: number, body: number[], size: number) => {
    const count = Math.max(1, Math.ceil(body.length / size))
    return Array.from({ length: count }, (_, index) => ({ frame, index, count, bytes: new Uint8Array(body.slice(index * size, (index + 1) * size)) }))
  }

  test('reassembles in-order chunks', () => {
    const a = new FrameAssembler()
    const parts = chunks(1, [1, 2, 3, 4, 5], 2)
    expect(a.push(parts[0])).toEqual({ lost: false })
    expect(a.push(parts[1])).toEqual({ lost: false })
    expect(a.push(parts[2])).toEqual({ body: new Uint8Array([1, 2, 3, 4, 5]), lost: false })
    expect(a.push(chunks(2, [9], 4)[0])).toEqual({ body: new Uint8Array([9]), lost: false })
    expect(a.lost).toBe(0)
  })

  test('a missing chunk loses the frame, the next frame still arrives', () => {
    const a = new FrameAssembler()
    const one = chunks(1, [1, 2, 3, 4], 2)
    a.push(one[0])
    // one[1] never comes; frame 2 starts.
    expect(a.push(chunks(2, [7, 8], 2)[0])).toEqual({ body: new Uint8Array([7, 8]), lost: true })
    expect(a.lost).toBe(1)
  })

  test('a hole in the middle drops the rest of the frame once', () => {
    const a = new FrameAssembler()
    const parts = chunks(1, [1, 2, 3, 4, 5, 6], 2)
    a.push(parts[0])
    expect(a.push(parts[2])).toEqual({ lost: true })
    expect(a.push(chunks(2, [1], 2)[0]).lost).toBe(false)
    expect(a.lost).toBe(1)
  })

  test('a frame that vanished entirely counts as lost', () => {
    const a = new FrameAssembler()
    a.push(chunks(1, [1], 2)[0])
    expect(a.push(chunks(3, [3], 2)[0])).toEqual({ body: new Uint8Array([3]), lost: true })
  })
})
