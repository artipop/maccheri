import CoreMedia
import Foundation
import IOSurface
import VideoToolbox

/// Scales simulator frames and encodes them as low-latency H.264 (settings from bench/stream).
final class VideoEncoder {
    struct Output {
        var isKeyframe: Bool
        var parameterSets: [Data]
        /// AVCC: 4-byte big-endian NAL lengths.
        var payload: Data
        var encodeMicros: UInt32
    }

    let width: Int
    let height: Int
    private let session: VTCompressionSession
    private let transfer: VTPixelTransferSession
    private let pool: CVPixelBufferPool
    private var source: (surface: IOSurfaceRef, buffer: CVPixelBuffer)?
    /// The last scaled frame, re-encoded when a keyframe is needed while the screen is idle.
    private(set) var lastFrame: CVPixelBuffer?
    private var frameIndex: Int64 = 0

    init(width: Int, height: Int, bitrate: Int, fps: Int) throws {
        self.width = width
        self.height = height
        var session: VTCompressionSession?
        // Low-latency rate control is the mode meant for video calls; it implies no B-frames.
        let spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
        ]
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        guard status == noErr, let session else { throw NSError(domain: "simstream", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "H.264 encoder: \(status)"]) }
        self.session = session
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        // Constrained Baseline and PrioritizeEncodingSpeedOverQuality were tried: no faster in
        // the guest, and Baseline decodes slower on the client.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        // Periodic keyframes; frames only come when the screen changes, so cap by time too.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: (fps * 5) as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 5 as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(session)

        var transfer: VTPixelTransferSession?
        status = VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &transfer)
        guard status == noErr, let transfer else { throw NSError(domain: "simstream", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "pixel transfer: \(status)"]) }
        self.transfer = transfer
        VTSessionSetProperty(transfer, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal)

        var pool: CVPixelBufferPool?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary, attrs as CFDictionary, &pool)
        guard let pool else { throw NSError(domain: "simstream", code: 1, userInfo: [NSLocalizedDescriptionKey: "pixel buffer pool"]) }
        self.pool = pool
    }

    /// Copies the simulator framebuffer into a scaled buffer right away (the simulator keeps
    /// drawing into the same surface). Call on the screen queue.
    func scale(_ surface: IOSurfaceRef) -> CVPixelBuffer? {
        if source?.surface !== surface {
            var buffer: Unmanaged<CVPixelBuffer>?
            guard CVPixelBufferCreateWithIOSurface(nil, surface, nil, &buffer) == kCVReturnSuccess, let buffer else { return nil }
            source = (surface, buffer.takeRetainedValue())
        }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        guard VTPixelTransferSessionTransferImage(transfer, from: source!.buffer, to: out) == noErr else { return nil }
        lastFrame = out
        return out
    }

    /// Encodes asynchronously; `done` runs on a VideoToolbox thread.
    func encode(_ buffer: CVPixelBuffer, keyframe: Bool, startedAt start: UInt64, done: @escaping (Output) -> Void) {
        frameIndex += 1
        let properties = keyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let pts = CMTime(value: frameIndex, timescale: 600)
        VTCompressionSessionEncodeFrame(session, imageBuffer: buffer, presentationTimeStamp: pts, duration: .invalid, frameProperties: properties, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample, let block = CMSampleBufferGetDataBuffer(sample) else { return }
            let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]]
            let isKey = !((attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) ?? false)
            var sets: [Data] = []
            if isKey, let format = CMSampleBufferGetFormatDescription(sample) {
                var count = 0
                CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
                for i in 0..<count {
                    var pointer: UnsafePointer<UInt8>?
                    var size = 0
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: i, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size, parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                    if let pointer { sets.append(Data(bytes: pointer, count: size)) }
                }
            }
            var payload = Data(count: CMBlockBufferGetDataLength(block))
            payload.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!) }
            let micros = UInt32(clamping: (DispatchTime.now().uptimeNanoseconds - start) / 1000)
            done(Output(isKeyframe: isKey, parameterSets: sets, payload: payload, encodeMicros: micros))
        }
    }
}
