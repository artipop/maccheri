import Foundation
import IOSurface
import ObjectiveC

/// The device's framebuffer, delivered as an IOSurface whenever it changes.
public final class SimScreen: @unchecked Sendable {
    /// Called on ``queue`` for every changed frame, with the current surface and the uptime in ms.
    public var onFrame: ((IOSurfaceRef, Double) -> Void)?

    public let queue = DispatchQueue(label: "sim-screen", qos: .userInteractive)
    public private(set) var screenID: UInt32 = 0
    private let device: SimDevice
    private var screen: NSObject?
    private var registration: NSUUID?
    private var surface: IOSurfaceRef?
    private var watchdog: DispatchSourceTimer?
    /// The SimDeviceScreen wrappers; kept alive alongside the screens they vend.
    private var wrappers: [NSObject] = []

    public init(device: SimDevice) {
        self.device = device
    }

    /// The latest framebuffer; nil until the first surfaces-changed callback.
    public var currentSurface: IOSurfaceRef? { queue.sync { surface } }
    /// Same, for callers already on ``queue``.
    public var currentSurfaceOnQueue: IOSurfaceRef? {
        dispatchPrecondition(condition: .onQueue(queue))
        return surface
    }

    /// Starts callbacks. For a few seconds after `simctl boot` returns the main screen (ID 1) is
    /// missing while the other IDs exist and never get a surface, so this waits up to
    /// `mainScreenTimeout` for it. Sometimes the first registration after a boot never gets a
    /// surface either; then it re-registers, and after two misses moves on to the next screen ID.
    public func start(mainScreenTimeout: TimeInterval = 60) throws {
        var found = try Self.screens(of: device)
        if !found.contains(where: { $0.0 == 1 }) {
            print("waiting for the simulator's main screen")
            let deadline = Date().addingTimeInterval(mainScreenTimeout)
            while !found.contains(where: { $0.0 == 1 }), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.5)
                found = try Self.screens(of: device)
            }
        }
        let screens = found.map { ($0.0, $0.1) }
        guard !screens.isEmpty else { throw SimulatorBridgeError.call("SimDeviceScreen: no screen on device", nil) }
        queue.sync {
            wrappers = found.map(\.2)
            attach(screens, attempt: 0)
        }
    }

    public func stop() {
        queue.sync {
            watchdog?.cancel()
            watchdog = nil
            unregister()
        }
    }

    private func attach(_ screens: [(UInt32, NSObject)], attempt: Int) {
        let (id, screen) = screens[(attempt / 2) % screens.count]
        unregister()
        self.screen = screen
        screenID = id
        register(screen)
        watchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.surface == nil else { return }
            FileHandle.standardError.write(Data("simulator screen \(id): no surface after 2 s, re-registering\n".utf8))
            self.attach(screens, attempt: attempt + 1)
        }
        timer.resume()
        watchdog = timer
    }

    private func register(_ screen: NSObject) {
        typealias RegisterFn = @convention(c) (AnyObject, Selector, NSUUID, DispatchQueue, AnyObject, AnyObject, AnyObject) -> Void
        let selector = "registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:"
        let register = PrivateAPI.method(screen, selector, as: RegisterFn.self)
        let frame: @convention(block) () -> Void = { [weak self] in self?.deliver() }
        let surfaces: @convention(block) (AnyObject?, AnyObject?) -> Void = { [weak self] unmasked, masked in
            guard let self else { return }
            // IOSurface objects bridge to IOSurfaceRef.
            if let s = unmasked ?? masked { self.surface = unsafeBitCast(s, to: IOSurfaceRef.self) }
            self.deliver()
        }
        let properties: @convention(block) (AnyObject?) -> Void = { _ in }
        let uuid = NSUUID()
        registration = uuid
        register(screen, NSSelectorFromString(selector), uuid, queue, frame as AnyObject, surfaces as AnyObject, properties as AnyObject)
    }

    private func unregister() {
        guard let screen, let registration else { return }
        let sel = NSSelectorFromString("unregisterScreenCallbacksWithUUID:")
        if screen.responds(to: sel) { screen.perform(sel, with: registration) }
        self.registration = nil
    }

    private func deliver() {
        guard let surface else { return }
        onFrame?(surface, Double(DispatchTime.now().uptimeNanoseconds) / 1e6)
    }

    /// Candidate screens, main screen (ID 1 on iPhone) first.
    private static func screens(of device: SimDevice) throws -> [(UInt32, NSObject, NSObject)] {
        typealias InitFn = @convention(c) (AnyObject, Selector, AnyObject, UInt32) -> AnyObject?
        let screenClass: AnyClass = try PrivateAPI.cls("_TtC12SimulatorKit15SimDeviceScreen")
        let sel = NSSelectorFromString("initWithDevice:screenID:")
        let initScreen = unsafeBitCast(class_getMethodImplementation(screenClass, sel), to: InitFn.self)
        return [UInt32(1), 0, 2].compactMap { id in
            guard let wrapper = initScreen(PrivateAPI.alloc(screenClass), sel, device.object, id) as? NSObject,
                  let screen = wrapper.value(forKey: "screen") as? NSObject else { return nil }
            return (id, screen, wrapper)
        }
    }
}
