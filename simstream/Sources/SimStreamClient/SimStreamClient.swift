import CoreMedia
import Foundation
import Network
import SimStreamProtocol
import VideoToolbox

@_exported import SimStreamProtocol

public func uptimeMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

/// Connects to `simstream`, decodes its video and sends touches. All callbacks run on ``queue``.
public final class SimStreamClient: @unchecked Sendable {
    public enum State: Sendable, Equatable {
        case connecting
        case connected
        case disconnected(String?)
    }

    public struct Frame: @unchecked Sendable {
        /// BGRA, IOSurface-backed.
        public var image: CVPixelBuffer
        public var inputAck: UInt32
        public var decodedAtMs: Double
        /// Set when this frame completed a click → frame measurement.
        public var clickLatencyMs: Double?
    }

    public struct Stats: Sendable {
        public var fps: Double = 0
        public var mbps: Double = 0
        public var rttMs: Double?
        public var lastLatencyMs: Double?
        public var p50Ms: Double?
        public var p95Ms: Double?
        /// Server's share (touch received → frame sent) at p50.
        public var serverP50Ms: Double?
        public var samples = 0
        public var decodeP50Ms: Double?

        public init() {}
    }

    public let queue = DispatchQueue(label: "simstream-client", qos: .userInteractive)
    public var onState: ((State) -> Void)?
    public var onHello: ((Hello) -> Void)?
    public var onFrame: ((Frame) -> Void)?
    /// Twice a second.
    public var onStats: ((Stats) -> Void)?

    public private(set) var hello: Hello?
    public private(set) var tracker = LatencyTracker()

    private let connection: NWConnection
    private var reader = MessageReader()
    private var nextTouchID: UInt32 = 1
    private var decoder: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var lastKeyframeRequest = 0.0
    private var timer: DispatchSourceTimer?
    private var rttMs: Double?
    private var window = (frames: 0, bytes: 0, start: uptimeMs())
    private var decodeMs: [Double] = []

    public init(host: String, port: UInt16) {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.serviceClass = .interactiveVideo
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: parameters)
    }

    public func connect() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .preparing, .setup: self.onState?(.connecting)
            case .ready:
                self.onState?(.connected)
                self.startTimer()
            case .waiting(let error): self.onState?(.disconnected("\(error)"))
            case .failed(let error): self.onState?(.disconnected("\(error)")); self.stop()
            case .cancelled: self.onState?(.disconnected(nil)); self.stop()
            @unknown default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    public func disconnect() {
        connection.cancel()
    }

    /// Sends a touch at a point normalised to the screen; returns its id. Thread-safe.
    @discardableResult
    public func touch(_ phase: Touch.Phase, x: Double, y: Double) -> UInt32 {
        queue.sync {
            let t = Touch(id: nextTouchID, phase: phase, x: Float(min(max(x, 0), 1)), y: Float(min(max(y, 0), 1)))
            nextTouchID += 1
            tracker.sent(t, atMs: uptimeMs())
            send(.touch(t))
            return t.id
        }
    }

    private func send(_ message: SimStreamMessage) {
        connection.send(content: message.encoded(), completion: .idempotent)
    }

    private func stop() {
        timer?.cancel()
        timer = nil
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        decoder = nil
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func tick() {
        send(.ping(UInt64(uptimeMs() * 1000)))
        let now = uptimeMs()
        let seconds = max((now - window.start) / 1000, 0.001)
        var stats = Stats()
        stats.fps = Double(window.frames) / seconds
        stats.mbps = Double(window.bytes * 8) / seconds / 1e6
        stats.rttMs = rttMs
        stats.lastLatencyMs = tracker.last
        stats.p50Ms = tracker.percentile(0.5)
        stats.p95Ms = tracker.percentile(0.95)
        stats.serverP50Ms = LatencyTracker.percentile(tracker.serverSamples, 0.5)
        stats.samples = tracker.samples.count
        stats.decodeP50Ms = LatencyTracker.percentile(decodeMs, 0.5)
        window = (0, 0, now)
        if decodeMs.count > 600 { decodeMs.removeFirst(decodeMs.count - 600) }
        onStats?(stats)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data {
                self.window.bytes += data.count
                do {
                    for message in try self.reader.append(data) { self.handle(message) }
                } catch {
                    self.onState?(.disconnected("bad stream: \(error)"))
                    self.connection.cancel()
                    return
                }
            }
            if isComplete || error != nil {
                self.connection.cancel()
                return
            }
            self.receive()
        }
    }

    private func handle(_ message: SimStreamMessage) {
        switch message {
        case .hello(let h):
            hello = h
            onHello?(h)
        case .video(let v):
            decode(v)
        case .ping(let v):
            send(.pong(v))
        case .pong(let v):
            rttMs = uptimeMs() - Double(v) / 1000
        case .touch, .requestKeyframe:
            break
        }
    }

    // MARK: - Decoding

    private func decode(_ v: VideoFrame) {
        if v.isKeyframe, v.parameterSets.count >= 2, !makeDecoder(v.parameterSets) { return requestKeyframe() }
        guard let decoder, let format else { return requestKeyframe() }
        var block: CMBlockBuffer?
        let payload = v.payload
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: payload.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: payload.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr, let block else { return }
        payload.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count) }
        var sample: CMSampleBuffer?
        var size = payload.count
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return }

        let start = uptimeMs()
        var image: CVPixelBuffer?
        // No async flag: the output handler runs before this returns.
        let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
            if status == noErr { image = buffer }
        }
        guard status == noErr, let image else { return requestKeyframe() }
        let now = uptimeMs()
        decodeMs.append(now - start)
        window.frames += 1
        let latency = tracker.frame(inputAck: v.inputAck, ackAgeMicros: v.ackAgeMicros, decodedAtMs: now)
        onFrame?(Frame(image: image, inputAck: v.inputAck, decodedAtMs: now, clickLatencyMs: latency))
    }

    private func makeDecoder(_ sets: [Data]) -> Bool {
        var newFormat: CMVideoFormatDescription?
        let status = sets[0].withUnsafeBytes { sps in
            sets[1].withUnsafeBytes { pps in
                let pointers = [sps.bindMemory(to: UInt8.self).baseAddress!, pps.bindMemory(to: UInt8.self).baseAddress!]
                let sizes = [sets[0].count, sets[1].count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: nil, parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat)
            }
        }
        guard status == noErr, let newFormat else { return false }
        if let decoder, let format, VTDecompressionSessionCanAcceptFormatDescription(decoder, formatDescription: newFormat) {
            if !CMFormatDescriptionEqual(format, otherFormatDescription: newFormat) { self.format = newFormat }
            return true
        }
        if let decoder { VTDecompressionSessionInvalidate(decoder) }
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: nil, formatDescription: newFormat, decoderSpecification: spec as CFDictionary, imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &session) == noErr, let session else { return false }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        decoder = session
        format = newFormat
        return true
    }

    private func requestKeyframe() {
        let now = uptimeMs()
        guard now - lastKeyframeRequest > 250 else { return }
        lastKeyframeRequest = now
        send(.requestKeyframe)
    }
}
