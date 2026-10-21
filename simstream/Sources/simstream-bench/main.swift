// simstream-bench --host 127.0.0.1 [--port 7300] [--taps 60] [--hold 60]
//
// Headless simstream client for latency runs. With TapProbe in the foreground (it flips the screen
// black/white on every touch-down) it taps the screen centre N times and reports click → decoded
// frame two ways: by `inputAck` (what the viewer overlay shows) and by watching the centre pixel
// flip in the decoded frames (independent of the ack bookkeeping).

import CoreVideo
import Foundation
import SimStreamClient

setvbuf(stdout, nil, _IOLBF, 0)

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    return a.firstIndex(of: name).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
}

let host = arg("--host") ?? "127.0.0.1"
let port = arg("--port").flatMap(UInt16.init) ?? SimStream.defaultPort
let taps = arg("--taps").flatMap(Int.init) ?? 60
let holdMs = arg("--hold").flatMap(Double.init) ?? 60

/// Brightness of the centre pixel of a BGRA frame.
func centreIsBright(_ image: CVPixelBuffer) -> Bool {
    CVPixelBufferLockBaseAddress(image, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let row = CVPixelBufferGetBaseAddress(image)! + CVPixelBufferGetHeight(image) / 2 * CVPixelBufferGetBytesPerRow(image)
    let pixel = row.load(fromByteOffset: CVPixelBufferGetWidth(image) / 2 * 4, as: UInt32.self)
    return (pixel & 0xff) > 128
}

let client = SimStreamClient(host: host, port: port)
let lock = NSLock()
var bright: Bool?
var flip: (sentMs: Double, before: Bool, semaphore: DispatchSemaphore)?
var pixelLatency: [Double] = []
var frames = 0
var lastStats = SimStreamClient.Stats()
let firstFrame = DispatchSemaphore(value: 0)

client.onState = { state in
    if case .disconnected(let reason) = state {
        print("disconnected: \(reason ?? "closed")")
        exit(1)
    }
}
client.onHello = { h in print("hello: \(h.deviceName) \(h.screenWidth)×\(h.screenHeight), video \(h.videoWidth)×\(h.videoHeight)") }
client.onFrame = { frame in
    let isBright = centreIsBright(frame.image)
    lock.withLock {
        frames += 1
        if frames == 1 { firstFrame.signal() }
        bright = isBright
        if let f = flip, isBright != f.before {
            pixelLatency.append(frame.decodedAtMs - f.sentMs)
            flip = nil
            f.semaphore.signal()
        }
    }
}
client.onStats = { s in lock.withLock { lastStats = s } }
client.connect()

guard firstFrame.wait(timeout: .now() + 10) == .success else {
    print("no video within 10 s")
    exit(1)
}
usleep(500_000)

var missed = 0
for i in 0..<taps {
    usleep(useconds_t(Int.random(in: 250_000...400_000)))
    let semaphore = DispatchSemaphore(value: 0)
    lock.withLock { flip = (uptimeMs(), bright ?? false, semaphore) }
    client.touch(.began, x: 0.5, y: 0.5)
    let ok = semaphore.wait(timeout: .now() + 1) == .success
    if !ok {
        missed += 1
        lock.withLock { flip = nil }
        if i == 0 { print("first tap changed nothing — is TapProbe in the foreground?") }
    }
    usleep(useconds_t(holdMs * 1000))
    client.touch(.ended, x: 0.5, y: 0.5)
}
usleep(600_000)

let tracker = client.queue.sync { client.tracker }
let stats = lock.withLock { lastStats }
func fmt(_ v: Double?) -> String { v.map { String(format: "%.1f", $0) } ?? "–" }
func line(_ name: String, _ values: [Double]) {
    let p = { LatencyTracker.percentile(values, $0) }
    print("\(name): n \(values.count)  p50 \(fmt(p(0.5)))  p95 \(fmt(p(0.95)))  min \(fmt(values.min()))  max \(fmt(values.max())) ms")
}
print("taps \(taps), missed \(missed), host \(host):\(port)")
line("click → decoded frame (pixel flip)", lock.withLock { pixelLatency })
line("click → decoded frame (inputAck)  ", tracker.samples)
line("  of which server (touch → sent)  ", tracker.serverSamples)
print("RTT \(fmt(stats.rttMs)) ms, decode p50 \(fmt(stats.decodeP50Ms)) ms")
exit(0)
