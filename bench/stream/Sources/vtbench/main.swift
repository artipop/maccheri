// Measures how long VideoToolbox takes to encode and decode simulator-sized frames in real time.
//
// Frames are produced at a fixed rate (default 60 fps) so the numbers are latency under a live
// stream, not peak throughput. The same binary runs on the host and inside a macOS guest to see
// whether the guest has a hardware encoder.
//
//   swift run -c release vtbench [--fps 60] [--seconds 5] [--json out.json]

import CoreMedia
import CoreText
import Foundation
import VideoToolbox

struct Config {
    var name: String
    var codec: CMVideoCodecType
    var width: Int32
    var height: Int32
    var bitrate: Int
}

struct Result: Codable {
    var name: String
    var codec: String
    var width: Int32
    var height: Int32
    var hardware: Bool?
    var lowLatencyRC: Bool
    var frames: Int
    var droppedFrames: Int
    var encodeP50ms: Double
    var encodeP95ms: Double
    var encodeMaxms: Double
    var decodeP50ms: Double
    var decodeP95ms: Double
    var totalP50ms: Double
    var totalP95ms: Double
    var avgFrameKB: Double
    var mbps: Double
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

func percentile(_ values: [Double], _ p: Double) -> Double {
    guard !values.isEmpty else { return .nan }
    let sorted = values.sorted()
    return sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))]
}

func fourCC(_ code: CMVideoCodecType) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((code >> $0) & 0xff) }, encoding: .ascii) ?? "\(code)"
}

/// Draws something that looks like an app screen: a scrolling list of text rows with a header,
/// so the encoder sees mostly flat areas, sharp text and vertical motion, like real UI.
final class FrameSource {
    let width: Int, height: Int
    private let pool: CVPixelBufferPool
    private let font = CTFontCreateWithName("Helvetica" as CFString, 34, nil)

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        var pool: CVPixelBufferPool?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        self.pool = pool!
    }

    func frame(_ index: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        let pb = buffer!
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )!
        ctx.setFillColor(CGColor(gray: 0.97, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        let rowHeight = 120.0
        let scroll = Double(index * 6).truncatingRemainder(dividingBy: rowHeight * 40)
        var y = Double(height) + scroll
        var row = 0
        while y > -rowHeight {
            y -= rowHeight
            row += 1
            ctx.setFillColor(CGColor(gray: 0.85, alpha: 1))
            ctx.fill(CGRect(x: 40, y: y, width: Double(width) - 80, height: 1))
            ctx.setFillColor(CGColor(red: CGFloat(row % 7) / 7, green: 0.5, blue: 0.9, alpha: 1))
            ctx.fillEllipse(in: CGRect(x: 40, y: y + 25, width: 70, height: 70))
            draw("Row \(row) · build #\(row * 37 % 1000) passed in \(row % 60)s", at: CGPoint(x: 140, y: y + 50), in: ctx)
        }
        ctx.setFillColor(CGColor(red: 0.1, green: 0.4, blue: 0.95, alpha: 1))
        ctx.fill(CGRect(x: 0, y: Double(height) - 260, width: Double(width), height: 260))
        draw("Frame \(index)", at: CGPoint(x: 40, y: Double(height) - 180), in: ctx)
        return pb
    }

    private func draw(_ text: String, at point: CGPoint, in ctx: CGContext) {
        let attributed = NSAttributedString(string: text, attributes: [kCTFontAttributeName as NSAttributedString.Key: font])
        let line = CTLineCreateWithAttributedString(attributed)
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }
}

final class Pipeline {
    let config: Config
    var encoder: VTCompressionSession?
    var decoder: VTDecompressionSession?
    var lowLatencyRC = false
    let lock = NSLock()
    var submitted: [Int: Double] = [:]
    var encoded: [Int: Double] = [:]
    var encodeMs: [Double] = []
    var decodeMs: [Double] = []
    var totalMs: [Double] = []
    var bytes = 0
    var outputFrames = 0
    /// The first frames include encoder start-up; they are encoded but not measured.
    var warmupFrames = 60
    let decodeQueue = DispatchQueue(label: "decode")

    init(config: Config) throws {
        self.config = config
        try makeEncoder()
    }

    private func makeEncoder() throws {
        // Low-latency rate control is the mode meant for video calls; fall back if the codec lacks it.
        for lowLatency in (CommandLine.arguments.contains("--no-llrc") ? [false] : [true, false]) {
            var spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
            if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            var session: VTCompressionSession?
            let status = VTCompressionSessionCreate(
                allocator: nil, width: config.width, height: config.height, codecType: config.codec,
                encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session
            )
            if status == noErr, let session {
                encoder = session
                lowLatencyRC = lowLatency
                break
            }
        }
        guard let encoder else { throw NSError(domain: "vtbench", code: 1, userInfo: [NSLocalizedDescriptionKey: "cannot create \(fourCC(config.codec)) encoder"]) }
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_AverageBitRate, value: config.bitrate as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 60 as CFNumber)
        VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 600 as CFNumber)
        if config.codec == kCMVideoCodecType_H264 {
            VTSessionSetProperty(encoder, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        }
        VTCompressionSessionPrepareToEncodeFrames(encoder)
    }

    /// Whether a session that insists on a hardware encoder can be created for this codec and size.
    var isHardware: Bool? {
        var probe: VTCompressionSession?
        let spec: [CFString: Any] = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true]
        let probeStatus = VTCompressionSessionCreate(
            allocator: nil, width: config.width, height: config.height, codecType: config.codec,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &probe
        )
        if let probe { VTCompressionSessionInvalidate(probe) }
        if probeStatus != noErr { return false }
        guard let encoder else { return nil }
        var value: Unmanaged<CFTypeRef>?
        let status = withUnsafeMutablePointer(to: &value) {
            VTSessionCopyProperty(encoder, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, allocator: nil, valueOut: UnsafeMutableRawPointer($0))
        }
        guard status == noErr, let value else { return true }
        return (value.takeRetainedValue() as? Bool) ?? true
    }

    func encode(_ pb: CVPixelBuffer, index: Int) {
        let t = now()
        lock.withLock { submitted[index] = t }
        let pts = CMTime(value: CMTimeValue(index), timescale: 60)
        VTCompressionSessionEncodeFrame(encoder!, imageBuffer: pb, presentationTimeStamp: pts, duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { [self] status, _, sample in
            guard status == noErr, let sample else { return }
            let done = now()
            lock.withLock {
                guard index >= warmupFrames else { return }
                if let start = submitted[index] { encodeMs.append(done - start) }
                encoded[index] = done
                bytes += CMSampleBufferGetTotalSampleSize(sample)
                outputFrames += 1
            }
            decodeQueue.async { self.decode(sample, index: index) }
        }
    }

    private func decode(_ sample: CMSampleBuffer, index: Int) {
        if decoder == nil {
            let format = CMSampleBufferGetFormatDescription(sample)!
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
            let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
            VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: spec as CFDictionary, imageBufferAttributes: attrs as CFDictionary, outputCallback: nil, decompressionSessionOut: &decoder)
            if let decoder { VTSessionSetProperty(decoder, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue) }
        }
        guard let decoder else { return }
        let start = now()
        VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { [self] status, _, image, _, _ in
            guard status == noErr, image != nil else { return }
            let done = now()
            lock.withLock {
                guard index >= warmupFrames else { return }
                decodeMs.append(done - start)
                if let submit = submitted[index] { totalMs.append(done - submit) }
            }
        }
    }

    func finish() {
        VTCompressionSessionCompleteFrames(encoder!, untilPresentationTimeStamp: .invalid)
        decodeQueue.sync {}
        if let decoder { VTDecompressionSessionWaitForAsynchronousFrames(decoder) }
    }
}

func run(_ config: Config, fps: Double, seconds: Double) throws -> Result {
    let source = FrameSource(width: Int(config.width), height: Int(config.height))
    let pipeline = try Pipeline(config: config)
    let frameCount = Int(fps * seconds)
    let interval = 1000 / fps
    pipeline.warmupFrames = Int(fps)
    let start = now()
    var dropped = 0
    // Pre-render frames so drawing time does not end up in the encode measurement.
    let frames = (0..<min(frameCount, 120)).map { source.frame($0) }
    for i in 0..<frameCount {
        let deadline = start + Double(i) * interval
        let wait = deadline - now()
        if wait > 0 { usleep(useconds_t(wait * 1000)) } else if wait < -interval, i >= Int(fps) { dropped += 1 }
        pipeline.encode(frames[i % frames.count], index: i)
    }
    pipeline.finish()

    let elapsed = (now() - start) / 1000 - 1 // minus the warm-up second
    return Result(
        name: config.name, codec: fourCC(config.codec), width: config.width, height: config.height,
        hardware: pipeline.isHardware, lowLatencyRC: pipeline.lowLatencyRC,
        frames: pipeline.outputFrames, droppedFrames: dropped,
        encodeP50ms: percentile(pipeline.encodeMs, 0.5), encodeP95ms: percentile(pipeline.encodeMs, 0.95),
        encodeMaxms: pipeline.encodeMs.max() ?? .nan,
        decodeP50ms: percentile(pipeline.decodeMs, 0.5), decodeP95ms: percentile(pipeline.decodeMs, 0.95),
        totalP50ms: percentile(pipeline.totalMs, 0.5), totalP95ms: percentile(pipeline.totalMs, 0.95),
        avgFrameKB: Double(pipeline.bytes) / Double(max(pipeline.outputFrames, 1)) / 1024,
        mbps: Double(pipeline.bytes * 8) / elapsed / 1e6
    )
}

func arg(_ name: String) -> String? {
    let a = CommandLine.arguments
    return a.firstIndex(of: name).flatMap { $0 + 1 < a.count ? a[$0 + 1] : nil }
}

let fps = arg("--fps").flatMap(Double.init) ?? 60
let seconds = arg("--seconds").flatMap(Double.init) ?? 5

// iPhone 17 Pro-class panel is 1206×2622; streams usually go at half resolution.
let configs = [
    Config(name: "full", codec: kCMVideoCodecType_H264, width: 1206, height: 2622, bitrate: 8_000_000),
    Config(name: "half", codec: kCMVideoCodecType_H264, width: 603, height: 1311, bitrate: 3_000_000),
    Config(name: "full", codec: kCMVideoCodecType_HEVC, width: 1206, height: 2622, bitrate: 6_000_000),
    Config(name: "half", codec: kCMVideoCodecType_HEVC, width: 603, height: 1311, bitrate: 2_000_000),
]

var hostInfo: [String: String] = [:]
var size = 0
sysctlbyname("kern.hv_vmm_present", nil, &size, nil, 0)
var vmm: Int32 = 0
size = MemoryLayout<Int32>.size
sysctlbyname("kern.hv_vmm_present", &vmm, &size, nil, 0)
hostInfo["virtualized"] = vmm == 1 ? "true" : "false"
hostInfo["macos"] = ProcessInfo.processInfo.operatingSystemVersionString

var encoders: CFArray?
VTCopyVideoEncoderList(nil, &encoders)
let hwEncoders = ((encoders as? [[String: Any]]) ?? [])
    .filter { ($0[kVTVideoEncoderList_IsHardwareAccelerated as String] as? Bool) == true }
    .compactMap { $0[kVTVideoEncoderList_DisplayName as String] as? String }
hostInfo["hardwareEncoders"] = hwEncoders.joined(separator: ", ")
print("virtualized=\(hostInfo["virtualized"]!)  hardware encoders: \(hwEncoders.isEmpty ? "none" : hostInfo["hardwareEncoders"]!)")

var results: [Result] = []
print("codec size        hw    llrc  enc p50/p95/max ms   dec p50/p95 ms  total p50/p95 ms  KB/frame  Mbit/s  dropped")
for config in configs {
    do {
        let r = try run(config, fps: fps, seconds: seconds)
        results.append(r)
        print(String(format: "%@  %4dx%-5d %-5@ %-5@ %5.1f/%5.1f/%5.1f      %5.1f/%5.1f     %5.1f/%5.1f      %6.1f   %5.1f   %d",
                     r.codec, r.width, r.height, r.hardware.map { "\($0)" } ?? "?", "\(r.lowLatencyRC)",
                     r.encodeP50ms, r.encodeP95ms, r.encodeMaxms, r.decodeP50ms, r.decodeP95ms,
                     r.totalP50ms, r.totalP95ms, r.avgFrameKB, r.mbps, r.droppedFrames))
    } catch {
        print("\(fourCC(config.codec)) \(config.name): \(error.localizedDescription)")
    }
}

if let out = arg("--json") {
    struct Report: Codable { var host: [String: String]; var fps: Double; var results: [Result] }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(Report(host: hostInfo, fps: fps, results: results)).write(to: URL(fileURLWithPath: out))
}
