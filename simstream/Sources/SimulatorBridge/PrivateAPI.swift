// Every private CoreSimulator / SimulatorKit interface maccheri uses lives in this module. They are
// what Simulator.app itself uses, and they are tied to the Xcode they were checked against (27.2):
// expect breakage on Xcode upgrades and re-check the signatures below with `otool -tV`.
//
// CoreSimulator  /Library/Developer/PrivateFrameworks/CoreSimulator.framework
//   +[SimServiceContext sharedServiceContextForDeveloperDir:(NSString *) error:(NSError **)]
//   -[SimServiceContext defaultDeviceSetWithError:(NSError **)] -> SimDeviceSet
//   SimDeviceSet.devices -> [SimDevice]; SimDevice.UDID (NSUUID), .name, .state
//
// SimulatorKit  <Xcode>/Contents/SharedFrameworks/SimulatorKit.framework
//   -[SimulatorKit.SimDeviceScreen initWithDevice:(SimDevice *) screenID:(uint32_t)]   iPhone main screen = 1
//   SimDeviceScreen.screen -> object answering
//     registerScreenCallbacksWithUUID:(NSUUID *) callbackQueue:(dispatch_queue_t)
//         frameCallback:(void (^)(void))
//         surfacesChangedCallback:(void (^)(IOSurface *unmasked, IOSurface *masked))
//         propertiesChangedCallback:(void (^)(id))
//     unregisterScreenCallbacksWithUUID:(NSUUID *)
//   Frame callbacks fire only when the framebuffer changes; an idle screen sends nothing.
//
//   -[SimulatorKit.SimDeviceLegacyHIDClient initWithDevice:(SimDevice *) error:(NSError **)]
//   -[… sendWithMessage:(IndigoMessage *) freeWhenDone:(BOOL) completionQueue:(dispatch_queue_t)
//         completion:(void (^)(NSError *))]
//
//   IndigoMessage *IndigoHIDMessageForMouseNSEvent(CGPoint *point, CGPoint *point2,
//         uint32_t target, NSEventType type, uint32_t edge, CGSize screenSize)
//     Xcode 27 added `screenSize` (passed in d0/d1); the message carries point / screenSize, so a
//     normalised point with size 1×1 works. idb's five-argument form leaves the size as garbage,
//     the ratio comes out as inf and the touch is silently lost. target 0x32 = main digitizer.
//     Mouse-moved/dragged events closer than 16 ms to the previous one are dropped inside the
//     function; down and up always pass.
//
//   IndigoMessage *IndigoHIDMessageForKeyboardArbitrary(uint32_t usage, uint32_t direction)
//     USB HID usage on the keyboard page; direction 1 = down, 2 = up.
//   IndigoMessage *IndigoHIDMessageForButton(uint32_t source, uint32_t direction, uint32_t target)
//     source: home 0, lock 1, side button 0xbb8, Siri 0x400002; target 0x33 = hardware buttons.
//   IndigoMessage *IndigoHIDMessageForHIDArbitrary(uint32_t target, uint32_t page, uint32_t usage,
//         uint32_t direction)
//     Any usage, e.g. consumer page 0x0c volume up 0xe9 / down 0xea, target 0x32.
//
// GraphicsServices events (rotation) are not Indigo: they are mach messages to the guest's
// `PurpleWorkspacePort` (`-[SimDevice lookup:(NSString *) error:(NSError **)] -> mach_port_t`),
// 108 bytes: mach header with id 0x7b, GSEvent type at 0x18 (| 0x20000 host flag), payload size at
// 0x48, payload at 0x4c. Device orientation changed = 50 with a UIDeviceOrientation (as idb does).
// The framebuffer stays in portrait when the device rotates: the content turns inside it, and the
// viewer turns the picture back.

import AppKit
import Foundation
import ObjectiveC

public enum SimulatorBridgeError: Error, CustomStringConvertible {
    case frameworkMissing(String)
    case classMissing(String)
    case symbolMissing(String)
    case deviceNotFound(String)
    case call(String, NSError?)

    public var description: String {
        switch self {
        case .frameworkMissing(let s): "cannot load \(s)"
        case .classMissing(let s): "class \(s) not found (Xcode version?)"
        case .symbolMissing(let s): "symbol \(s) not found (Xcode version?)"
        case .deviceNotFound(let s): "simulator \(s) not found"
        case .call(let s, let e): "\(s) failed: \(e?.localizedDescription ?? "nil")"
        }
    }
}

enum PrivateAPI {
    static let developerDir = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Applications/Xcode-beta.app/Contents/Developer"

    private static let loaded: Result<UnsafeMutableRawPointer, SimulatorBridgeError> = {
        let coreSimulator = "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator"
        let simulatorKit = URL(fileURLWithPath: developerDir).deletingLastPathComponent()
            .appendingPathComponent("SharedFrameworks/SimulatorKit.framework/SimulatorKit").path
        guard dlopen(coreSimulator, RTLD_NOW) != nil else { return .failure(.frameworkMissing(coreSimulator)) }
        guard let kit = dlopen(simulatorKit, RTLD_NOW) else { return .failure(.frameworkMissing(simulatorKit)) }
        return .success(kit)
    }()

    /// dlopen handle of SimulatorKit; loads both frameworks on first use.
    static func simulatorKit() throws -> UnsafeMutableRawPointer { try loaded.get() }

    static func cls(_ name: String) throws -> AnyClass {
        _ = try simulatorKit()
        guard let c = NSClassFromString(name) else { throw SimulatorBridgeError.classMissing(name) }
        return c
    }

    static func alloc(_ c: AnyClass) -> AnyObject {
        (c as! NSObject.Type).perform(NSSelectorFromString("alloc")).takeUnretainedValue()
    }

    /// IMP of `selector` on `object`, cast to the given C function type.
    static func method<F>(_ object: AnyObject, _ selector: String, as: F.Type) -> F {
        unsafeBitCast(class_getMethodImplementation(object_getClass(object), NSSelectorFromString(selector)), to: F.self)
    }
}

/// A simulator device from the default device set.
public final class SimDevice: @unchecked Sendable {
    let object: NSObject
    public let udid: String
    public var name: String { object.value(forKey: "name") as? String ?? "?" }

    public init(udid: String) throws {
        typealias ContextFn = @convention(c) (AnyClass, Selector, NSString, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        typealias DeviceSetFn = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        let contextClass: AnyClass = try PrivateAPI.cls("SimServiceContext")
        let sel = NSSelectorFromString("sharedServiceContextForDeveloperDir:error:")
        let makeContext = unsafeBitCast(method_getImplementation(class_getClassMethod(contextClass, sel)!), to: ContextFn.self)
        var error: NSError?
        guard let context = makeContext(contextClass, sel, PrivateAPI.developerDir as NSString, &error) else {
            throw SimulatorBridgeError.call("sharedServiceContextForDeveloperDir", error)
        }
        let getSet = PrivateAPI.method(context, "defaultDeviceSetWithError:", as: DeviceSetFn.self)
        guard let set = getSet(context, NSSelectorFromString("defaultDeviceSetWithError:"), &error) as? NSObject else {
            throw SimulatorBridgeError.call("defaultDeviceSetWithError", error)
        }
        let devices = set.value(forKey: "devices") as? [NSObject] ?? []
        guard let device = devices.first(where: { ($0.value(forKey: "UDID") as? NSUUID)?.uuidString == udid.uppercased() }) else {
            throw SimulatorBridgeError.deviceNotFound(udid)
        }
        object = device
        self.udid = udid.uppercased()
    }
}

/// HID injection through `SimDeviceLegacyHIDClient` + `IndigoHIDMessageForMouseNSEvent`.
public final class SimTouchInjector: @unchecked Sendable {
    public enum Phase: Sendable {
        case down, drag, up
    }

    private typealias MouseMessageFn = @convention(c) (UnsafeMutablePointer<CGPoint>, UnsafeMutablePointer<CGPoint>?, UInt32, UInt, UInt32, CGSize) -> UnsafeMutableRawPointer?
    private typealias SendFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, Bool, DispatchQueue, AnyObject) -> Void

    private let client: NSObject
    private let makeMessage: MouseMessageFn
    private let sendFn: SendFn
    private let queue = DispatchQueue(label: "hid", qos: .userInteractive)

    public init(device: SimDevice) throws {
        typealias InitFn = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        let clientClass: AnyClass = try PrivateAPI.cls("_TtC12SimulatorKit24SimDeviceLegacyHIDClient")
        let sel = NSSelectorFromString("initWithDevice:error:")
        let initClient = unsafeBitCast(class_getMethodImplementation(clientClass, sel), to: InitFn.self)
        var error: NSError?
        guard let client = initClient(PrivateAPI.alloc(clientClass), sel, device.object, &error) as? NSObject else {
            throw SimulatorBridgeError.call("SimDeviceLegacyHIDClient init", error)
        }
        self.client = client
        guard let symbol = dlsym(try PrivateAPI.simulatorKit(), "IndigoHIDMessageForMouseNSEvent") else {
            throw SimulatorBridgeError.symbolMissing("IndigoHIDMessageForMouseNSEvent")
        }
        makeMessage = unsafeBitCast(symbol, to: MouseMessageFn.self)
        sendFn = PrivateAPI.method(client, "sendWithMessage:freeWhenDone:completionQueue:completion:", as: SendFn.self)
    }

    /// Sends one event at a point normalised to the screen (0…1 from the top-left). `completion`
    /// runs on a private queue once the simulator has taken the message.
    public func send(_ phase: Phase, x: Double, y: Double, completion: @escaping @Sendable (Error?) -> Void = { _ in }) {
        var point = CGPoint(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
        let type: NSEvent.EventType = switch phase {
        case .down: .leftMouseDown
        case .drag: .leftMouseDragged
        case .up: .leftMouseUp
        }
        guard let message = makeMessage(&point, nil, 0x32, type.rawValue, 0, CGSize(width: 1, height: 1)) else {
            // Dropped by the function itself (a drag too soon after the previous one).
            queue.async { completion(nil) }
            return
        }
        let done: @convention(block) (NSError?) -> Void = { error in completion(error) }
        sendFn(client, NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:"), message, true, queue, done as AnyObject)
    }
}

/// Keys, hardware buttons and rotation. Shares the HID client with nothing: CoreSimulator accepts
/// several clients per device.
public final class SimDeviceControls: @unchecked Sendable {
    public enum Button: Sendable {
        case home, lock, sideButton, siri, volumeUp, volumeDown
    }

    private typealias KeyboardFn = @convention(c) (UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias ButtonFn = @convention(c) (UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias ArbitraryFn = @convention(c) (UInt32, UInt32, UInt32, UInt32) -> UnsafeMutableRawPointer?
    private typealias SendFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer, Bool, DispatchQueue, AnyObject) -> Void
    private typealias LookupFn = @convention(c) (AnyObject, Selector, NSString, UnsafeMutablePointer<NSError?>?) -> UInt32

    private let device: SimDevice
    private let client: NSObject
    private let keyboard: KeyboardFn
    private let button: ButtonFn
    private let arbitrary: ArbitraryFn
    private let sendFn: SendFn
    private let queue = DispatchQueue(label: "hid-controls", qos: .userInteractive)

    public init(device: SimDevice) throws {
        self.device = device
        typealias InitFn = @convention(c) (AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>?) -> AnyObject?
        let clientClass: AnyClass = try PrivateAPI.cls("_TtC12SimulatorKit24SimDeviceLegacyHIDClient")
        let sel = NSSelectorFromString("initWithDevice:error:")
        let initClient = unsafeBitCast(class_getMethodImplementation(clientClass, sel), to: InitFn.self)
        var error: NSError?
        guard let client = initClient(PrivateAPI.alloc(clientClass), sel, device.object, &error) as? NSObject else {
            throw SimulatorBridgeError.call("SimDeviceLegacyHIDClient init", error)
        }
        self.client = client
        let kit = try PrivateAPI.simulatorKit()
        func symbol<F>(_ name: String, as: F.Type) throws -> F {
            guard let p = dlsym(kit, name) else { throw SimulatorBridgeError.symbolMissing(name) }
            return unsafeBitCast(p, to: F.self)
        }
        keyboard = try symbol("IndigoHIDMessageForKeyboardArbitrary", as: KeyboardFn.self)
        button = try symbol("IndigoHIDMessageForButton", as: ButtonFn.self)
        arbitrary = try symbol("IndigoHIDMessageForHIDArbitrary", as: ArbitraryFn.self)
        sendFn = PrivateAPI.method(client, "sendWithMessage:freeWhenDone:completionQueue:completion:", as: SendFn.self)
    }

    private func send(_ message: UnsafeMutableRawPointer?, _ what: String) {
        guard let message else { return print("HID: no message for \(what)") }
        let done: @convention(block) (NSError?) -> Void = { error in
            if let error { print("HID \(what): \(error.localizedDescription)") }
        }
        sendFn(client, NSSelectorFromString("sendWithMessage:freeWhenDone:completionQueue:completion:"), message, true, queue, done as AnyObject)
    }

    /// A key on the USB HID keyboard page (0x07).
    public func key(usage: UInt16, down: Bool) {
        send(keyboard(UInt32(usage), down ? 1 : 2), "key \(usage)")
    }

    public func button(_ b: Button, down: Bool) {
        let direction: UInt32 = down ? 1 : 2
        switch b {
        case .home: send(button(0, direction, 0x33), "home")
        case .lock: send(button(1, direction, 0x33), "lock")
        case .sideButton: send(button(0xbb8, direction, 0x33), "side button")
        case .siri: send(button(0x40_0002, direction, 0x33), "siri")
        case .volumeUp: send(arbitrary(0x32, 0x0c, 0xe9, direction), "volume up")
        case .volumeDown: send(arbitrary(0x32, 0x0c, 0xea, direction), "volume down")
        }
    }

    /// Debugging: one Indigo button event from raw values, or a consumer-page usage when `page` is set.
    public func rawButton(source: UInt32, target: UInt32, page: UInt32?, down: Bool) {
        if let page {
            send(arbitrary(target, page, source, down ? 1 : 2), "usage \(page):\(source)")
        } else {
            send(button(source, down ? 1 : 2, target), "button \(source)")
        }
    }

    /// Rotates the device; `orientation` is a UIDeviceOrientation (1 portrait … 4 landscape right).
    public func setOrientation(_ orientation: UInt32) throws {
        try sendGSEvent(type: 50, payload: orientation)
    }

    private func sendGSEvent(type: UInt32, payload: UInt32?) throws {
        let lookup = PrivateAPI.method(device.object, "lookup:error:", as: LookupFn.self)
        var error: NSError?
        let port = lookup(device.object, NSSelectorFromString("lookup:error:"), "PurpleWorkspacePort", &error)
        guard port != 0 else { throw SimulatorBridgeError.call("lookup PurpleWorkspacePort", error) }
        var buffer = [UInt8](repeating: 0, count: 112)
        func put(_ value: UInt32, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { buffer.replaceSubrange(offset..<offset + 4, with: $0) }
        }
        put(0x13, at: 0x00) // MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0)
        put(108, at: 0x04)
        put(port, at: 0x08)
        put(0x7b, at: 0x14)
        put(type | 0x2_0000, at: 0x18)
        if let payload {
            put(4, at: 0x48)
            put(payload, at: 0x4c)
        }
        let result = buffer.withUnsafeMutableBytes { raw -> kern_return_t in
            let header = raw.baseAddress!.assumingMemoryBound(to: mach_msg_header_t.self)
            return mach_msg(header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, 108, 0, mach_port_t(MACH_PORT_NULL), 2000, mach_port_t(MACH_PORT_NULL))
        }
        guard result == KERN_SUCCESS else { throw SimulatorBridgeError.call("GSEvent \(type): \(String(cString: mach_error_string(result)))", nil) }
    }
}
