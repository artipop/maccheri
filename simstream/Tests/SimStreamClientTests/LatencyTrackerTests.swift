import Testing
@testable import SimStreamClient

@Test func measuresPressToFirstAckingFrame() {
    var t = LatencyTracker()
    t.sent(Touch(id: 1, phase: .began, x: 0, y: 0), atMs: 100)
    #expect(t.frame(inputAck: 0, ackAgeMicros: 0, decodedAtMs: 105) == nil)
    #expect(t.frame(inputAck: 1, ackAgeMicros: 9_000, decodedAtMs: 125) == 25)
    // Later frames with the same ack are not new samples.
    #expect(t.frame(inputAck: 1, ackAgeMicros: 0, decodedAtMs: 140) == nil)
    #expect(t.samples == [25])
    #expect(t.serverSamples == [9])
}

@Test func releaseBeforeFrameMakesSampleAmbiguous() {
    var t = LatencyTracker()
    t.sent(Touch(id: 1, phase: .began, x: 0, y: 0), atMs: 0)
    t.sent(Touch(id: 2, phase: .ended, x: 0, y: 0), atMs: 10)
    // The frame already includes the release: it may be showing the release, not the press.
    #expect(t.frame(inputAck: 2, ackAgeMicros: 0, decodedAtMs: 30) == nil)
    #expect(t.samples.isEmpty)

    t.sent(Touch(id: 3, phase: .began, x: 0, y: 0), atMs: 100)
    t.sent(Touch(id: 4, phase: .ended, x: 0, y: 0), atMs: 110)
    #expect(t.frame(inputAck: 3, ackAgeMicros: 0, decodedAtMs: 120) == 20)
}

@Test func dragDuringPressStillCounts() {
    var t = LatencyTracker()
    t.sent(Touch(id: 1, phase: .began, x: 0, y: 0), atMs: 0)
    t.sent(Touch(id: 2, phase: .moved, x: 0.1, y: 0), atMs: 5)
    #expect(t.frame(inputAck: 2, ackAgeMicros: 0, decodedAtMs: 22) == 22)
}

@Test func keepsAWindowAndPercentiles() {
    var t = LatencyTracker(window: 10)
    for i in 1...30 {
        t.sent(Touch(id: UInt32(i), phase: .began, x: 0, y: 0), atMs: 0)
        t.frame(inputAck: UInt32(i), ackAgeMicros: 0, decodedAtMs: Double(i))
    }
    #expect(t.samples == (21...30).map(Double.init))
    #expect(t.percentile(0.5) == 26)
    #expect(t.percentile(0.95) == 30)
    #expect(LatencyTracker.percentile([], 0.5) == nil)
}
