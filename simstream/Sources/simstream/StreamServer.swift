import CoreVideo
import Foundation
import IOSurface
import Network
import SimStreamProtocol
import SimulatorBridge

func uptimeMicros() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1000 }

/// Serves one client at a time: video out, touches in. A new connection replaces the old one.
final class StreamServer {
    struct Options {
        var port: UInt16
        var scale: Double
        var fpsCap: Int
        var bitrate: Int
    }

    private let options: Options
    private let device: SimDevice
    private let screen: SimScreen
    private let touch: SimTouchInjector
    private let encoder: VideoEncoder
    private let hello: Hello
    private let listener: NWListener
    /// Network, touch and pacing state; frames are scaled on the screen queue.
    private let queue = DispatchQueue(label: "server", qos: .userInteractive)

    private var client: NWConnection?
    private var reader = MessageReader()
    /// Bytes handed to the socket and not yet written; frames are dropped above `maxQueued`.
    private var queuedBytes = 0
    private let maxQueued = 512 << 10
    private var needKeyframe = true

    // Touch → frame bookkeeping. `acked` is the newest touch the simulator has taken.
    private var acked: (id: UInt32, receivedMicros: UInt64) = (0, 0)
    private var received: [UInt32: UInt64] = [:]
    private var lastDrag: UInt64 = 0
    private var pendingDrag: Touch?

    // Pacing (screen queue).
    private var lastEncodeMicros: UInt64 = 0
    private var deferred = false
    private var latestSurface: IOSurfaceRef?
    private var latestCallbackMicros: UInt64 = 0

    /// `SIMSTREAM_TRACE=1`: one line per frame that carries a new touch, with where the time went.
    private let trace = ProcessInfo.processInfo.environment["SIMSTREAM_TRACE"] == "1"
    private var tracedAck: UInt32 = 0

    // Stats (server queue).
    private var stats = (frames: 0, bytes: 0, dropped: 0, keyframes: 0, encodeMicros: [UInt32]())

    init(device: SimDevice, screen: SimScreen, touch: SimTouchInjector, options: Options) throws {
        self.device = device
        self.screen = screen
        self.touch = touch
        self.options = options
        guard let surface = screen.currentSurface else { throw NSError(domain: "simstream", code: 2, userInfo: [NSLocalizedDescriptionKey: "no frames from the simulator screen"]) }
        let screenWidth = IOSurfaceGetWidth(surface), screenHeight = IOSurfaceGetHeight(surface)
        // 4:2:0 wants even dimensions.
        let width = max(16, Int(Double(screenWidth) * options.scale) & ~1)
        let height = max(16, Int(Double(screenHeight) * options.scale) & ~1)
        encoder = try VideoEncoder(width: width, height: height, bitrate: options.bitrate, fps: options.fpsCap)
        hello = Hello(
            screenWidth: UInt32(screenWidth), screenHeight: UInt32(screenHeight),
            videoWidth: UInt32(width), videoHeight: UInt32(height),
            codec: 0x6176_6331, // avc1
            deviceID: device.udid, deviceName: device.name
        )
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: NWEndpoint.Port(rawValue: options.port)!)
    }

    func start() {
        print("screen \(hello.screenWidth)×\(hello.screenHeight) → video \(hello.videoWidth)×\(hello.videoHeight), \(options.bitrate / 1000) kbit/s, cap \(options.fpsCap) fps")
        screen.queue.sync { latestSurface = screen.currentSurfaceOnQueue }
        screen.onFrame = { [weak self] surface, _ in self?.frameChanged(surface) }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { state in
            if case .ready = state { print("listening on :\(self.options.port)") }
            if case .failed(let error) = state { print("listener failed: \(error)"); exit(1) }
        }
        listener.start(queue: queue)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in self?.logStats() }
        timer.resume()
        statsTimer = timer
    }

    private var statsTimer: DispatchSourceTimer?

    // MARK: - Connection

    private func accept(_ connection: NWConnection) {
        if let old = client {
            print("replacing client \(old.endpoint)")
            old.cancel()
        }
        client = connection
        reader = MessageReader()
        queuedBytes = 0
        // Touch ids restart at 1 with every client.
        acked = (0, 0)
        received = [:]
        pendingDrag = nil
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .ready:
                print("client \(connection.endpoint)")
                self.send(.hello(self.hello))
                self.needKeyframe = true
                self.screen.queue.async { self.resendLastFrame() }
            case .failed(let error):
                print("client \(connection.endpoint) failed: \(error)")
                self.drop(connection)
            case .cancelled:
                self.drop(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection)
    }

    private func drop(_ connection: NWConnection) {
        guard client === connection else { return }
        print("client \(connection.endpoint) gone")
        client = nil
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 << 10) { [weak self] data, _, isComplete, error in
            guard let self, self.client === connection else { return }
            if let data {
                do {
                    for message in try self.reader.append(data) { self.handle(message) }
                } catch {
                    print("bad message: \(error)")
                    connection.cancel()
                    return
                }
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection)
        }
    }

    private func send(_ message: SimStreamMessage) {
        guard let client else { return }
        let data = message.encoded()
        queuedBytes += data.count
        client.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.queue.async { self?.queuedBytes -= data.count }
        })
    }

    private func handle(_ message: SimStreamMessage) {
        switch message {
        case .touch(let t):
            received[t.id] = uptimeMicros()
            inject(t)
        case .requestKeyframe:
            needKeyframe = true
            screen.queue.async { self.resendLastFrame() }
        case .ping(let v):
            send(.pong(v))
        case .hello, .video, .pong:
            break
        }
    }

    // MARK: - Touch

    /// Drags closer than 16 ms apart are dropped by Indigo itself, so they are coalesced here:
    /// a drag inside the window waits until it opens, and only the newest one is sent.
    private func inject(_ t: Touch) {
        let dragInterval: UInt64 = 17_000
        switch t.phase {
        case .began:
            pendingDrag = nil
            hid(.down, t)
        case .ended:
            pendingDrag = nil
            hid(.up, t)
        case .moved:
            let now = uptimeMicros()
            if now - lastDrag >= dragInterval, pendingDrag == nil {
                lastDrag = now
                hid(.drag, t)
            } else {
                let scheduled = pendingDrag != nil
                pendingDrag = t
                if !scheduled {
                    let wait = Int(dragInterval - min(dragInterval, now - lastDrag))
                    queue.asyncAfter(deadline: .now() + .microseconds(wait)) { [weak self] in
                        guard let self, let drag = self.pendingDrag else { return }
                        self.pendingDrag = nil
                        self.lastDrag = uptimeMicros()
                        self.hid(.drag, drag)
                    }
                }
            }
        }
    }

    private func hid(_ phase: SimTouchInjector.Phase, _ t: Touch) {
        touch.send(phase, x: Double(t.x), y: Double(t.y)) { [weak self] error in
            guard let self else { return }
            if let error { print("HID error: \(error)") }
            self.queue.async {
                guard t.id > self.acked.id else { return }
                self.acked = (t.id, self.received[t.id] ?? uptimeMicros())
                self.received = self.received.filter { $0.key > t.id }
            }
        }
    }

    // MARK: - Frames (screen queue)

    private func frameChanged(_ surface: IOSurfaceRef) {
        latestSurface = surface
        latestCallbackMicros = uptimeMicros()
        let interval = UInt64(1_000_000 / max(options.fpsCap, 1))
        let now = uptimeMicros()
        if now - lastEncodeMicros >= interval {
            encode(surface)
        } else if !deferred {
            // Over the cap: encode whatever the screen shows once the interval is up.
            deferred = true
            screen.queue.asyncAfter(deadline: .now() + .microseconds(Int(interval - (now - lastEncodeMicros)))) { [weak self] in
                guard let self else { return }
                self.deferred = false
                if let surface = self.latestSurface { self.encode(surface) }
            }
        }
    }

    private func encode(_ surface: IOSurfaceRef) {
        let start = uptimeMicros()
        lastEncodeMicros = start
        // The ack is read before the copy. It says the simulator had the touch, not that the app
        // has redrawn for it yet: a frame already in flight can carry it (at most a frame early).
        let ack = queue.sync { acked }
        guard let buffer = encoder.scale(surface) else { return }
        if trace, ack.id != tracedAck {
            tracedAck = ack.id
            let ms = { (a: UInt64, b: UInt64) in String(format: "%.1f", Double(Int64(b) - Int64(a)) / 1000) }
            print("trace touch \(ack.id): received → frame callback \(ms(ack.receivedMicros, latestCallbackMicros)), callback → copy \(ms(latestCallbackMicros, start)), scale \(ms(start, uptimeMicros())) ms")
        }
        submit(buffer, ack: ack, start: start)
    }

    private func resendLastFrame() {
        guard let buffer = encoder.lastFrame ?? latestSurface.flatMap(encoder.scale) else { return }
        submit(buffer, ack: queue.sync { acked }, start: uptimeMicros())
    }

    private func submit(_ buffer: CVPixelBuffer, ack: (id: UInt32, receivedMicros: UInt64), start: UInt64) {
        let (wanted, skip) = queue.sync { () -> (Bool, Bool) in
            guard client != nil else { return (false, true) }
            if queuedBytes > maxQueued {
                // The socket is behind: drop this frame and restart the stream with a keyframe.
                stats.dropped += 1
                needKeyframe = true
                return (false, true)
            }
            defer { needKeyframe = false }
            return (needKeyframe, false)
        }
        if skip { return }
        encoder.encode(buffer, keyframe: wanted, startedAt: start * 1000) { [weak self] out in
            guard let self else { return }
            self.queue.async {
                let frame = VideoFrame(
                    isKeyframe: out.isKeyframe, inputAck: ack.id,
                    ackAgeMicros: ack.id == 0 ? 0 : UInt32(clamping: uptimeMicros() - ack.receivedMicros),
                    encodeMicros: out.encodeMicros, captureMicros: start,
                    parameterSets: out.parameterSets, payload: out.payload
                )
                self.send(.video(frame))
                self.stats.frames += 1
                self.stats.bytes += out.payload.count
                if out.isKeyframe { self.stats.keyframes += 1 }
                self.stats.encodeMicros.append(out.encodeMicros)
            }
        }
    }

    private func logStats() {
        guard stats.frames > 0 || client != nil else { return }
        let sorted = stats.encodeMicros.sorted()
        let p50 = sorted.isEmpty ? 0 : Double(sorted[sorted.count / 2]) / 1000
        let p95 = sorted.isEmpty ? 0 : Double(sorted[min(sorted.count - 1, sorted.count * 95 / 100)]) / 1000
        print(String(format: "5 s: %d frames (%d key, %d dropped), %.2f Mbit/s, scale+encode p50 %.1f p95 %.1f ms",
                     stats.frames, stats.keyframes, stats.dropped, Double(stats.bytes * 8) / 5e6, p50, p95))
        stats = (0, 0, 0, 0, [])
    }
}
