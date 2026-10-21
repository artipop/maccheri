import { expect, test } from 'vitest'
import { LatencyTracker, percentile } from '../src/latency'
import { hidUsage } from '../src/keyboard'

test('measures from began to the first frame that acks it', () => {
  const t = new LatencyTracker()
  t.sent(1, 'began', 100)
  expect(t.frame(0, 0, 110)).toBeNull()
  expect(t.frame(1, 15_000, 125)).toBe(25)
  expect(t.serverSamples).toEqual([15])
  // Already measured: later frames don't count again.
  expect(t.frame(2, 0, 130)).toBeNull()
})

test('drops a sample when the release was already in', () => {
  const t = new LatencyTracker()
  t.sent(1, 'began', 0)
  t.sent(2, 'ended', 10)
  expect(t.frame(2, 0, 40)).toBeNull()
  expect(t.samples).toEqual([])
})

test('keeps a window of samples', () => {
  const t = new LatencyTracker(3)
  for (let i = 1; i <= 5; i++) { t.sent(i, 'began', 0); t.frame(i, 0, i) }
  expect(t.samples).toEqual([3, 4, 5])
  expect(t.percentile(0.5)).toBe(4)
  expect(percentile([], 0.5)).toBeNull()
})

test('maps KeyboardEvent.code to HID usages', () => {
  expect(hidUsage('KeyA')).toBe(0x04)
  expect(hidUsage('KeyZ')).toBe(0x1d)
  expect(hidUsage('Digit1')).toBe(0x1e)
  expect(hidUsage('Digit0')).toBe(0x27)
  expect(hidUsage('Enter')).toBe(0x28)
  expect(hidUsage('ArrowUp')).toBe(0x52)
  expect(hidUsage('ShiftLeft')).toBe(0xe1)
  expect(hidUsage('MetaRight')).toBe(0xe7)
  expect(hidUsage('MediaPlayPause')).toBeNull()
})
