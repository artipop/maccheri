// Input-to-frame latency of an iOS Simulator, measured with the same private CoreSimulator /
// SimulatorKit interfaces Simulator.app uses: touches go in through SimDeviceLegacyHIDClient,
// frames come out of the device screen's IOSurface. Run TapProbe in the simulator first; it flips
// the screen black/white on every touch-down.
//
//   simlatency --udid <UDID> [--taps 40]
//
// The private CoreSimulator / SimulatorKit calls live in SimulatorBridge (simstream/).

import Foundation
import IOSurface
import SimulatorBridge

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    return a.firstIndex(of: name).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
}

/// Watches the device's framebuffer and reports when the centre pixel changes brightness.
final class ScreenWatcher {
    private let screen: SimScreen
    private(set) var frames = 0
    private var lastBright: Bool?
    var onFlip: ((Double, Bool) -> Void)?

    init(device: SimDevice) {
        screen = SimScreen(device: device)
        screen.onFrame = { [unowned self] surface, time in self.frameArrived(surface, at: time) }
    }

    func start() throws { try screen.start() }

    private func frameArrived(_ surface: IOSurfaceRef, at time: Double) {
        frames += 1
        IOSurfaceLock(surface, .readOnly, nil)
        let base = IOSurfaceGetBaseAddress(surface)
        let width = IOSurfaceGetWidth(surface), height = IOSurfaceGetHeight(surface)
        let rowBytes = IOSurfaceGetBytesPerRow(surface)
        let pixel = base.load(fromByteOffset: (height / 2) * rowBytes + (width / 2) * 4, as: UInt32.self)
        IOSurfaceUnlock(surface, .readOnly, nil)
        let bright = (pixel & 0xff) > 128
        if let last = lastBright, last != bright { onFlip?(time, bright) }
        lastBright = bright
    }

    var currentSize: (Int, Int)? {
        screen.currentSurface.map { (IOSurfaceGetWidth($0), IOSurfaceGetHeight($0)) }
    }
}

// MARK: - Measurement

guard let udid = arg("--udid") else {
    print("usage: simlatency --udid <UDID> [--taps 40]")
    exit(64)
}
let taps = arg("--taps").flatMap(Int.init) ?? 40

let device: SimDevice
let touch: SimTouchInjector
do {
    device = try SimDevice(udid: udid)
    touch = try SimTouchInjector(device: device)
} catch {
    print("error: \(error)")
    exit(1)
}
let watcher = ScreenWatcher(device: device)

let lock = NSLock()
var pendingTap: Double?
var flipSemaphore = DispatchSemaphore(value: 0)
var latencies: [Double] = []
var hidAck: [Double] = []

watcher.onFlip = { time, _ in
    lock.lock()
    defer { lock.unlock() }
    if let start = pendingTap {
        latencies.append(time - start)
        pendingTap = nil
        flipSemaphore.signal()
    }
}
try watcher.start()

// Wait for the first surface.
let waitStart = now()
while watcher.currentSize == nil, now() - waitStart < 5000 { usleep(10_000) }
guard let size = watcher.currentSize else { fatalError("no frames from the simulator screen") }
print("screen \(size.0)×\(size.1)")

// Idle frame rate: how often the simulator delivers frames when nothing changes.
let idleFramesStart = watcher.frames
usleep(1_000_000)
print("frames in 1 s idle: \(watcher.frames - idleFramesStart)")

var missed = 0
for i in 0..<taps {
    usleep(useconds_t(Int.random(in: 250_000...400_000)))
    let start = now()
    lock.withLock { pendingTap = start }
    touch.send(.down, x: 0.5, y: 0.5) { _ in lock.withLock { hidAck.append(now() - start) } }
    if flipSemaphore.wait(timeout: .now() + 1) == .timedOut {
        missed += 1
        lock.withLock { pendingTap = nil }
        if i == 0 { print("first tap produced no frame change — is TapProbe in the foreground?") }
    }
    touch.send(.up, x: 0.5, y: 0.5)
}

func pct(_ v: [Double], _ p: Double) -> Double {
    let s = v.sorted()
    return s.isEmpty ? .nan : s[min(s.count - 1, Int(Double(s.count - 1) * p))]
}
print(String(format: "taps %d, missed %d", taps, missed))
print(String(format: "touch → changed frame, ms: p50 %.1f  p95 %.1f  min %.1f  max %.1f",
             pct(latencies, 0.5), pct(latencies, 0.95), latencies.min() ?? .nan, latencies.max() ?? .nan))
print(String(format: "HID send → ack, ms: p50 %.2f  p95 %.2f", pct(hidAck, 0.5), pct(hidAck, 0.95)))
