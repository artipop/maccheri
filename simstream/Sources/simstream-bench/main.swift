// simstream-bench --host 127.0.0.1 [--port 7300] [--taps 60] [--hold 60]
// simstream-bench --host … --tap X,Y | --drag X,Y1,Y2     one gesture, for checking input by hand
// simstream-bench --host … --soak SECONDS                   random scrolling; counts all-black frames
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

/// Whether a sparse grid of pixels is all (near) black: a blank frame, which TapProbe aside never
/// shows up in real apps.
func isBlank(_ image: CVPixelBuffer) -> Bool {
    CVPixelBufferLockBaseAddress(image, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
    let base = CVPixelBufferGetBaseAddress(image)!, rowBytes = CVPixelBufferGetBytesPerRow(image)
    let w = CVPixelBufferGetWidth(image), h = CVPixelBufferGetHeight(image)
    for gy in 1..<16 {
        for gx in 1..<8 {
            let p = base.load(fromByteOffset: (h * gy / 16) * rowBytes + (w * gx / 8) * 4, as: UInt32.self)
            if (p & 0xff) > 24 || (p >> 8 & 0xff) > 24 || (p >> 16 & 0xff) > 24 { return false }
        }
    }
    return true
}

if let seconds = arg("--soak").flatMap(Double.init) {
    var blanks: [(Int, Double)] = []
    var total = 0
    client.onFrame = { frame in
        let blank = isBlank(frame.image)
        lock.withLock {
            total += 1
            if blank { blanks.append((total, frame.decodedAtMs)) }
        }
    }
    let end = uptimeMs() + seconds * 1000
    while uptimeMs() < end {
        let (y1, y2) = Bool.random() ? (0.75, 0.35) : (0.35, 0.75)
        client.touch(.began, x: 0.5, y: y1)
        for step in 1...20 {
            usleep(16_000)
            client.touch(.moved, x: 0.5, y: y1 + (y2 - y1) * Double(step) / 20)
        }
        client.touch(.ended, x: 0.5, y: y2)
        usleep(useconds_t(Int.random(in: 200_000...900_000)))
    }
    lock.withLock { print("frames \(total), blank \(blanks.count): \(blanks.prefix(20).map { "#\($0.0)" }.joined(separator: " "))") }
    exit(0)
}

/// One tap or a vertical drag at normalised coordinates, then exit.
func gesture(_ spec: String, drag: Bool) -> Never {
    let v = spec.split(separator: ",").compactMap { Double($0) }
    guard v.count == (drag ? 3 : 2) else { print("bad gesture \(spec)"); exit(64) }
    client.touch(.began, x: v[0], y: v[1])
    if drag {
        for step in 1...30 {
            usleep(16_000)
            client.touch(.moved, x: v[0], y: v[1] + (v[2] - v[1]) * Double(step) / 30)
        }
    } else {
        usleep(80_000)
    }
    client.touch(.ended, x: v[0], y: drag ? v[2] : v[1])
    usleep(500_000)
    exit(0)
}
if let spec = arg("--tap") { gesture(spec, drag: false) }
if let spec = arg("--drag") { gesture(spec, drag: true) }

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
