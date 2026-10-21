// Click → frame latency on the browser's clock, like simstream/Sources/SimStreamClient/LatencyTracker.swift:
// from sending a `began` touch to the first frame whose `inputAck` covers it. If the click's
// `ended` was already in the simulator when that frame was taken, the frame may show the release
// instead, and the sample is dropped.

export class LatencyTracker {
  private pending: { id: number; sentMs: number; limit: number } | null = null
  samples: number[] = []
  serverSamples: number[] = []

  constructor(readonly window = 200) {}

  sent(id: number, phase: 'began' | 'moved' | 'ended', atMs: number) {
    if (phase === 'began') this.pending = { id, sentMs: atMs, limit: Infinity }
    else if (phase === 'ended' && this.pending && this.pending.limit === Infinity) this.pending.limit = id
  }

  /** Feed every displayed frame; returns the new sample if this frame completed one. */
  frame(inputAck: number, ackAgeMicros: number, shownAtMs: number): number | null {
    const p = this.pending
    if (!p || inputAck < p.id) return null
    this.pending = null
    if (inputAck >= p.limit) return null
    const latency = shownAtMs - p.sentMs
    this.samples.push(latency)
    this.serverSamples.push(ackAgeMicros / 1000)
    if (this.samples.length > this.window) {
      this.samples.splice(0, this.samples.length - this.window)
      this.serverSamples.splice(0, this.serverSamples.length - this.window)
    }
    return latency
  }

  get last(): number | null { return this.samples.at(-1) ?? null }
  percentile(p: number): number | null { return percentile(this.samples, p) }
}

export function percentile(values: number[], p: number): number | null {
  if (values.length === 0) return null
  const sorted = [...values].sort((a, b) => a - b)
  return sorted[Math.min(sorted.length - 1, Math.round((sorted.length - 1) * p))]
}
