import Foundation
import SimStreamProtocol

/// Click → frame latency on the client's own clock: the time from sending a `began` touch to
/// decoding the first frame whose `inputAck` covers it.
///
/// Only `began` touches are measured. If the click's `ended` (or a later click) was already in the
/// simulator when the frame was taken, the frame could be showing that instead, so the sample is
/// thrown away rather than guessed at.
public struct LatencyTracker: Sendable {
    private var pending: (id: UInt32, sentMs: Double, limit: UInt32)?
    public private(set) var samples: [Double] = []
    /// Server part (touch received → frame sent) of each sample.
    public private(set) var serverSamples: [Double] = []
    public let window: Int

    public init(window: Int = 200) {
        self.window = window
    }

    public mutating func sent(_ touch: Touch, atMs time: Double) {
        switch touch.phase {
        case .began:
            pending = (touch.id, time, .max)
        case .ended:
            // Frames that already include this release no longer tell us about the press.
            if let p = pending, p.limit == .max { pending?.limit = touch.id }
        case .moved:
            break
        }
    }

    /// Feed every decoded frame; returns the new sample, if this frame completed one.
    @discardableResult
    public mutating func frame(inputAck: UInt32, ackAgeMicros: UInt32, decodedAtMs time: Double) -> Double? {
        guard let p = pending, inputAck >= p.id else { return nil }
        pending = nil
        guard inputAck < p.limit else { return nil }
        let latency = time - p.sentMs
        samples.append(latency)
        serverSamples.append(Double(ackAgeMicros) / 1000)
        if samples.count > window {
            samples.removeFirst(samples.count - window)
            serverSamples.removeFirst(serverSamples.count - window)
        }
        return latency
    }

    public var last: Double? { samples.last }
    public func percentile(_ p: Double) -> Double? { Self.percentile(samples, p) }

    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }
}
