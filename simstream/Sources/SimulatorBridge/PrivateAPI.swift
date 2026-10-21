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
