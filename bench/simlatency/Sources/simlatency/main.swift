// Input-to-frame latency of an iOS Simulator, measured with the same private CoreSimulator /
// SimulatorKit interfaces Simulator.app uses: touches go in through SimDeviceLegacyHIDClient,
// frames come out of the device screen's IOSurface. Run TapProbe in the simulator first; it flips
// the screen black/white on every touch-down.
//
//   simlatency --udid <UDID> [--taps 40]
//
// Private API: tied to the Xcode it was written against (27.2). Expect it to break on upgrades.

import AppKit
import Foundation
import IOSurface
import ObjectiveC

// MARK: - Loading private frameworks

let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Applications/Xcode-beta.app/Contents/Developer"
let simulatorKitPath = URL(fileURLWithPath: developerDir).deletingLastPathComponent()
    .appendingPathComponent("SharedFrameworks/SimulatorKit.framework/SimulatorKit").path

func load(_ path: String) -> UnsafeMutableRawPointer {
    guard let handle = dlopen(path, RTLD_NOW) else { fatalError("dlopen \(path): \(String(cString: dlerror()))") }
    return handle
}
_ = load("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator")
let simulatorKit = load(simulatorKitPath)

func cls(_ name: String) -> AnyClass {
    guard let c = NSClassFromString(name) else { fatalError("class \(name) not found") }
    return c
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    return a.firstIndex(of: name).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
}

// MARK: - Device

typealias ContextFn = @convention(c) (AnyClass, Selector, NSString, UnsafeMutablePointer<NSError?>?) -> AnyObject?
typealias DeviceSetFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> AnyObject?

func findDevice(udid: String) -> NSObject {
    let contextClass = cls("SimServiceContext")
    let sel = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
    let makeContext = unsafeBitCast(method_getImplementation(class_getClassMethod(contextClass, sel)!), to: ContextFn.self)
    var error: NSError?
    guard let context = makeContext(contextClass, sel, developerDir as NSString, &error) else { fatalError("service context: \(String(describing: error))") }
    let setSel = NSSelectorFromString("defaultDeviceSetWithError:")
    let getSet = unsafeBitCast(class_getMethodImplementation(object_getClass(context), setSel), to: DeviceSetFn.self)
    guard let set = getSet(context, setSel, &error) as? NSObject else { fatalError("device set: \(String(describing: error))") }
    let devices = set.value(forKey: "devices") as! [NSObject]
    guard let device = devices.first(where: { ($0.value(forKey: "UDID") as? NSUUID)?.uuidString == udid.uppercased() }) else {
        fatalError("device \(udid) not found")
    }
    return device
}

// MARK: - Screen

/// Watches the device's framebuffer and reports when the centre pixel changes brightness.
final class ScreenWatcher {
    private let queue = DispatchQueue(label: "screen", qos: .userInteractive)
    private var surface: IOSurfaceRef?
    private(set) var frames = 0
    private var lastBright: Bool?
    var onFlip: ((Double, Bool) -> Void)?
    let screen: NSObject

    init(device: NSObject) {
        let screenClass: AnyClass = cls("_TtC12SimulatorKit15SimDeviceScreen")
        typealias InitFn = @convention(c) (AnyObject, Selector, AnyObject, UInt32) -> AnyObject?
        let sel = NSSelectorFromString("initWithDevice:screenID:")
        let initScreen = unsafeBitCast(class_getMethodImplementation(screenClass, sel), to: InitFn.self)
        var found: NSObject?
        for id: UInt32 in [1, 0, 2] {
            let candidate = initScreen((screenClass as! NSObject.Type).perform(NSSelectorFromString("alloc")).takeUnretainedValue(), sel, device, id) as? NSObject
            if let s = candidate?.value(forKey: "screen") as? NSObject {
                found = s
                break
            }
        }
        guard let found else { fatalError("no screen on device") }
        screen = found
    }

    func start() {
        typealias RegisterFn = @convention(c) (AnyObject, Selector, NSUUID, DispatchQueue, AnyObject, AnyObject, AnyObject) -> Void
        let sel = NSSelectorFromString("registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:")
        let register = unsafeBitCast(class_getMethodImplementation(object_getClass(screen), sel), to: RegisterFn.self)

        let frame: @convention(block) () -> Void = { [unowned self] in self.frameArrived(at: now()) }
        let surfaces: @convention(block) (AnyObject?, AnyObject?) -> Void = { [unowned self] unmasked, masked in
            // IOSurface objects bridge to IOSurfaceRef.
            if let s = unmasked ?? masked { self.surface = unsafeBitCast(s, to: IOSurfaceRef.self) }
            self.frameArrived(at: now())
        }
        let properties: @convention(block) (AnyObject?) -> Void = { _ in }
        register(screen, sel, NSUUID(), queue, frame as AnyObject, surfaces as AnyObject, properties as AnyObject)
    }

    private func frameArrived(at time: Double) {
        guard let surface else { return }
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
        surface.map { (IOSurfaceGetWidth($0), IOSurfaceGetHeight($0)) }
    }
}

// MARK: - Touch input

/// Xcode 27: `IndigoHIDMessageForMouseNSEvent(CGPoint *point, CGPoint *point2, IndigoHIDTarget target,
/// NSEventType type, IndigoHIDEdge edge, CGSize screenSize)`; the message carries point / screenSize.
/// (idb's older five-argument form has no size, so the ratio comes out as inf and the touch is lost.)
typealias MouseMessageFn = @convention(c) (UnsafeMutablePointer<CGPoint>, UnsafeMutablePointer<CGPoint>?, UInt32, UInt, UInt, CGSize) -> UnsafeMutableRawPointer?

final class Touch {
    private let client: NSObject
    private let makeMessage: MouseMessageFn
    private let queue = DispatchQueue(label: "hid", qos: .userInteractive)

    init(device: NSObject) {
        let clientClass: AnyClass = cls("_TtC12SimulatorKit24SimDeviceLegacyHIDClient")
        typealias InitFn = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        let sel = NSSelectorFromString("initWithDevice:error:")
        let initClient = unsafeBitCast(class_getMethodImplementation(clientClass, sel), to: InitFn.self)
        var error: NSError?
        let alloc = (clientClass as! NSObject.Type).perform(NSSelectorFromString("alloc")).takeUnretainedValue()
        guard let client = initClient(alloc, sel, device, &error) as? NSObject else { fatalError("HID client: \(String(describing: error))") }
        self.client = client
        guard let symbol = dlsym(simulatorKit, "IndigoHIDMessageForMouseNSEvent") else { fatalError("IndigoHIDMessageForMouseNSEvent missing") }
        makeMessage = unsafeBitCast(symbol, to: MouseMessageFn.self)
    }

    /// Sends one mouse-down or mouse-up at the screen centre; returns when the simulator acknowledged it.
    func send(down: Bool, completion: @escaping (Double) -> Void) {
        var point = CGPoint(x: 0.5, y: 0.5)
        let type: NSEvent.EventType = down ? .leftMouseDown : .leftMouseUp
        // 0x32 is the digitizer target idb uses for the main screen.
        guard let message = makeMessage(&point, nil, 0x32, type.rawValue, 0, CGSize(width: 1, height: 1)) else { fatalError("no HID message") }
        typealias SendFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, Bool, DispatchQueue, AnyObject) -> Void
        let sel = NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:")
        let sendFn = unsafeBitCast(class_getMethodImplementation(object_getClass(client), sel), to: SendFn.self)
        let done: @convention(block) (NSError?) -> Void = { error in
            if let error { print("HID error: \(error)") }
            completion(now())
        }
        sendFn(client, sel, message, true, queue, done as AnyObject)
    }
}

// MARK: - Measurement

guard let udid = arg("--udid") else {
    print("usage: simlatency --udid <UDID> [--taps 40]")
    exit(64)
}
let taps = arg("--taps").flatMap(Int.init) ?? 40

let device = findDevice(udid: udid)
let watcher = ScreenWatcher(device: device)
let touch = Touch(device: device)

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
watcher.start()

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
    touch.send(down: true) { ack in lock.withLock { hidAck.append(ack - start) } }
    if flipSemaphore.wait(timeout: .now() + 1) == .timedOut {
        missed += 1
        lock.withLock { pendingTap = nil }
        if i == 0 { print("first tap produced no frame change — is TapProbe in the foreground?") }
    }
    touch.send(down: false) { _ in }
}

func pct(_ v: [Double], _ p: Double) -> Double {
    let s = v.sorted()
    return s.isEmpty ? .nan : s[min(s.count - 1, Int(Double(s.count - 1) * p))]
}
print(String(format: "taps %d, missed %d", taps, missed))
print(String(format: "touch → changed frame, ms: p50 %.1f  p95 %.1f  min %.1f  max %.1f",
             pct(latencies, 0.5), pct(latencies, 0.95), latencies.min() ?? .nan, latencies.max() ?? .nan))
print(String(format: "HID send → ack, ms: p50 %.2f  p95 %.2f", pct(hidAck, 0.5), pct(hidAck, 0.95)))
