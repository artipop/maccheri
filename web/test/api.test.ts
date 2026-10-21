// The TypeScript types in src/api.ts against the control plane's JSON fixtures
// (controlplane/Tests/Fixtures, generated from MaccheriProtocol). MACCHERI_FIXTURES overrides the
// directory; without fixtures the suite is skipped.
import { existsSync, readdirSync, readFileSync } from 'node:fs'
import { join } from 'node:path'
import { describe, expect, test } from 'vitest'
import { deviceName } from '../src/api'

const dir = process.env.MACCHERI_FIXTURES ?? join(__dirname, '../../controlplane/Tests/Fixtures')
const fixture = (name: string) => JSON.parse(readFileSync(join(dir, `${name}.json`), 'utf8'))

// A shape is a type in src/api.ts spelled out: required keys with their kind, `?` for optional.
type Shape = 'string' | 'number' | 'boolean' | 'uuid' | 'date' | Shape[] | { [key: string]: Shape } | ['?', Shape] | ['enum', ...string[]]
const opt = (s: Shape): Shape => ['?', s]

const DeviceSpec: Shape = { deviceType: 'string', runtime: 'string' }
const ICEServer: Shape = { urls: ['string'], username: opt('string'), credential: opt('string') }
const SignalingInfo: Shape = { url: 'string', token: 'string', iceServers: [ICEServer] }
const SessionInfo: Shape = {
  id: 'uuid', state: ['enum', 'queued', 'starting', 'ready', 'ended', 'failed'], device: opt(DeviceSpec),
  hostID: opt('uuid'), hostName: opt('string'), createdAt: 'date', expiresAt: 'date', signaling: opt(SignalingInfo), message: opt('string'),
}
const HostInfo: Shape = {
  id: 'uuid', name: 'string', ownerName: 'string', online: 'boolean',
  hardware: { model: 'string', chip: 'string', cpuCount: 'number', memoryBytes: 'number', macOSVersion: 'string' },
  capacity: opt({ freeSlots: 'number', warmVMs: 'number', images: ['string'], labels: ['string'], devices: [DeviceSpec] }),
}

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
  'create-session-request': { device: opt(DeviceSpec), hostID: opt('uuid') },
  'create-session-request-any': { device: opt(DeviceSpec), hostID: opt('uuid') },
  'redeem-invite-request': { code: 'string', name: 'string' },
  'user-token': { userID: 'uuid', token: 'string' },
  'user-info': { id: 'uuid', name: 'string', isAdmin: 'boolean' },
  invite: { code: 'string', expiresAt: 'date' },
  'signal-offer': { offer: { sdp: 'string' } },
  'signal-answer': { answer: { sdp: 'string' } },
  'signal-candidate': { candidate: { candidate: 'string', sdpMid: opt('string'), sdpMLineIndex: opt('number') } },
  'signal-candidate-end': { candidate: { candidate: 'string', sdpMid: opt('string'), sdpMLineIndex: opt('number') } },
  'signal-bye': { bye: { reason: opt('string') } },
  'signal-bye-empty': { bye: { reason: opt('string') } },
}

describe.skipIf(!existsSync(dir))('API types match the control plane fixtures', () => {
  test.each(Object.entries(shapes))('%s', (name, shape) => {
    expect(check(fixture(name), shape)).toEqual([])
  })

  test('every fixture the web client reads is covered', () => {
    const relevant = readdirSync(dir).filter((f) => /^(session-[a-z]+|hosts|signal-.*|user-.*|invite|redeem-.*|create-session-.*)\.json$/.test(f) && !f.startsWith('session-state'))
    expect(relevant.map((f) => f.replace(/\.json$/, '')).filter((n) => !(n in shapes))).toEqual([])
  })
})

test('device names', () => {
  expect(deviceName({ deviceType: 'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro', runtime: 'com.apple.CoreSimulator.SimRuntime.iOS-27-2' })).toBe('iPhone 17 Pro · iOS 27.2')
})
