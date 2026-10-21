import Foundation

/// Remote simulator stream, version 2.
///
/// One TCP connection carries everything. Each message is `UInt32 length` (big-endian, counts the
/// type byte and the payload), `UInt8 type`, payload. Integers are big-endian, floats are IEEE 754
/// bit patterns, strings and blobs carry a `UInt16` length.
///
/// Over WebRTC (host peer ⇄ browser) the same messages travel without the length prefix, one per
/// data channel message (``SimStreamMessage/encodedBody()``): `control` (reliable, ordered) carries
/// everything except video; video goes either as an RTP track plus ``FrameInfo`` on `control`, or
/// as ``VideoChunk``s on the `video` channel (``StreamConfig``).
///
/// The client measures click → frame on its own clock: it remembers when it sent touch N and waits
/// for a ``VideoFrame`` whose ``VideoFrame/inputAck`` is ≥ N. No clock sync between machines.
public enum SimStream {
    public static let version: UInt16 = 2
    public static let defaultPort: UInt16 = 7300
    /// Anything bigger is a corrupt stream, not a frame.
    public static let maxMessageSize = 16 << 20
}

public enum SimStreamMessage: Sendable, Equatable {
    /// Server → client, first message on every connection.
    case hello(Hello)
    /// Server → client.
    case video(VideoFrame)
    /// Client → server.
    case touch(Touch)
    /// Client → server: the decoder lost sync; send a keyframe now.
    case requestKeyframe
    /// Either direction; the peer answers with `pong` carrying the same value.
    case ping(UInt64)
    case pong(UInt64)
    /// Client → server: a hardware key (USB HID usage page 7).
    case key(KeyEvent)
    /// Client → server: a device button.
    case button(ButtonEvent)
    /// Client → server: rotate the device.
    case orientation(Orientation)
    /// Client → server: an app upload starts; `.app` zipped, `size` bytes follow in `installChunk`s.
    case installBegin(name: String, size: UInt64)
    case installChunk(Data)
    /// Client → server: all chunks sent; install and launch.
    case installEnd
    /// Server → client: progress and outcome of the upload.
    case installStatus(InstallStatus)
    /// Viewer → host peer (not forwarded to the guest): how to deliver video.
    case streamConfig(StreamConfig)
    /// Host peer → viewer, track mode: what the guest said about the frame with this RTP timestamp.
    case frameInfo(FrameInfo)
    /// Host peer → viewer, data channel mode: a slice of one encoded `video` message body.
    case videoChunk(VideoChunk)
}

/// A key press or release. `usage` is the USB HID usage on the keyboard page (0x07), e.g. 0x04 = A,
/// 0x28 = Return, 0xE1 = left shift; the same codes browsers' `KeyboardEvent.code` maps to.
public struct KeyEvent: Sendable, Equatable {
    public var usage: UInt16
    public var down: Bool

    public init(usage: UInt16, down: Bool) {
        self.usage = usage
        self.down = down
    }
}

public struct ButtonEvent: Sendable, Equatable {
    public enum Button: UInt8, Sendable, CaseIterable {
        case home = 0
        case lock = 1
        case siri = 2
        case volumeUp = 3
        case volumeDown = 4
    }

    public var button: Button
    public var down: Bool

    public init(button: Button, down: Bool) {
        self.button = button
        self.down = down
    }
}

/// UIDeviceOrientation values.
public enum Orientation: UInt8, Sendable, CaseIterable {
    case portrait = 1
    case portraitUpsideDown = 2
    /// Home button (or bottom edge) on the right.
    case landscapeLeft = 3
    case landscapeRight = 4
}

public struct InstallStatus: Sendable, Equatable {
    public enum State: UInt8, Sendable {
        case receiving = 0
        case installing = 1
        case launched = 2
        case failed = 3
    }

    public var state: State
    /// Bundle id once known, or the error.
    public var message: String

    public init(state: State, message: String) {
        self.state = state
        self.message = message
    }
}

public struct StreamConfig: Sendable, Equatable {
    public enum VideoTransport: UInt8, Sendable {
        /// RTP H.264 track, the browser's `<video>`; per-frame metadata as ``FrameInfo``.
        case track = 0
        /// ``VideoChunk``s on the `video` data channel; the browser decodes with WebCodecs.
        case dataChannel = 1
    }

    public var video: VideoTransport

    public init(video: VideoTransport) {
        self.video = video
    }
}

public struct FrameInfo: Sendable, Equatable {
    /// 90 kHz RTP timestamp of the frame, as `requestVideoFrameCallback` reports it.
    public var rtpTimestamp: UInt32
    public var isKeyframe: Bool
    public var inputAck: UInt32
    public var ackAgeMicros: UInt32
    public var encodeMicros: UInt32

    public init(rtpTimestamp: UInt32, isKeyframe: Bool, inputAck: UInt32, ackAgeMicros: UInt32, encodeMicros: UInt32) {
        self.rtpTimestamp = rtpTimestamp
        self.isKeyframe = isKeyframe
        self.inputAck = inputAck
        self.ackAgeMicros = ackAgeMicros
        self.encodeMicros = encodeMicros
    }
}

/// Frames are bigger than a data channel message may be in every browser, so they are sliced.
/// Slices of one frame are sent in order; a frame whose slices don't all arrive is lost.
public struct VideoChunk: Sendable, Equatable {
    /// Increases by one per frame.
    public var frame: UInt32
    public var index: UInt16
    public var count: UInt16
    public var bytes: Data

    public init(frame: UInt32, index: UInt16, count: UInt16, bytes: Data) {
        self.frame = frame
        self.index = index
        self.count = count
        self.bytes = bytes
    }

    /// Slices a `video` message body into chunks of at most `size` payload bytes.
    public static func slice(_ body: Data, frame: UInt32, size: Int) -> [VideoChunk] {
        let count = max(1, (body.count + size - 1) / size)
        return (0..<count).map { i in
            let start = body.startIndex + i * size
            return VideoChunk(frame: frame, index: UInt16(i), count: UInt16(count), bytes: Data(body[start..<min(start + size, body.endIndex)]))
        }
    }
}

public struct Hello: Sendable, Equatable {
    public var version: UInt16
    /// Simulator framebuffer, pixels.
    public var screenWidth: UInt32
    public var screenHeight: UInt32
    /// Encoded video, pixels.
    public var videoWidth: UInt32
    public var videoHeight: UInt32
    /// FourCC, e.g. `avc1` for H.264.
    public var codec: UInt32
    /// Simulator UDID.
    public var deviceID: String
    /// Human-readable device name, e.g. "iPhone 17 Pro".
    public var deviceName: String

    public init(version: UInt16 = SimStream.version, screenWidth: UInt32, screenHeight: UInt32, videoWidth: UInt32, videoHeight: UInt32, codec: UInt32, deviceID: String, deviceName: String) {
        self.version = version
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.videoWidth = videoWidth
        self.videoHeight = videoHeight
        self.codec = codec
        self.deviceID = deviceID
        self.deviceName = deviceName
    }
}

public struct VideoFrame: Sendable, Equatable {
    public var isKeyframe: Bool
    /// Id of the newest touch the simulator had processed before this frame was captured; 0 if none.
    public var inputAck: UInt32
    /// Server time from receiving touch `inputAck` to sending this frame, µs. Lets the client split
    /// its latency into server and network + client parts.
    public var ackAgeMicros: UInt32
    /// Scale + encode time on the server, µs.
    public var encodeMicros: UInt32
    /// Server capture time, µs on the server's monotonic clock; only differences mean anything.
    public var captureMicros: UInt64
    /// H.264 SPS and PPS (no start codes); present on keyframes.
    public var parameterSets: [Data]
    /// One access unit in AVCC layout: NAL units with 4-byte big-endian length prefixes.
    public var payload: Data

    public init(isKeyframe: Bool, inputAck: UInt32, ackAgeMicros: UInt32 = 0, encodeMicros: UInt32 = 0, captureMicros: UInt64 = 0, parameterSets: [Data] = [], payload: Data) {
        self.isKeyframe = isKeyframe
        self.inputAck = inputAck
        self.ackAgeMicros = ackAgeMicros
        self.encodeMicros = encodeMicros
        self.captureMicros = captureMicros
        self.parameterSets = parameterSets
        self.payload = payload
    }
}

public struct Touch: Sendable, Equatable {
    public enum Phase: UInt8, Sendable {
        case began = 0
        case moved = 1
        case ended = 2
    }

    /// Increases by one per touch event, starting at 1.
    public var id: UInt32
    public var phase: Phase
    /// Normalised to the screen, 0…1 from the top-left corner.
    public var x: Float
    public var y: Float

    public init(id: UInt32, phase: Phase, x: Float, y: Float) {
        self.id = id
        self.phase = phase
        self.x = x
        self.y = y
    }
}

public enum SimStreamError: Error, Equatable {
    case messageTooLarge(Int)
    case unknownType(UInt8)
    case truncated
    case badValue(String)
}

// MARK: - Encoding

enum MessageType: UInt8 {
    case hello = 1
    case video = 2
    case touch = 3
    case requestKeyframe = 4
    case ping = 5
    case pong = 6
    case key = 7
    case button = 8
    case orientation = 9
    case installBegin = 10
    case installChunk = 11
    case installEnd = 12
    case installStatus = 13
    case streamConfig = 14
    case frameInfo = 15
    case videoChunk = 16
}

extension SimStreamMessage {
    /// The message with its length prefix, ready to write to the socket.
    public func encoded() -> Data {
        var w = Writer()
        w.u32(0) // length, patched below
        switch self {
        case .hello(let h):
            w.u8(MessageType.hello.rawValue)
            w.u16(h.version)
            w.u32(h.screenWidth)
            w.u32(h.screenHeight)
            w.u32(h.videoWidth)
            w.u32(h.videoHeight)
            w.u32(h.codec)
            w.string(h.deviceID)
            w.string(h.deviceName)
        case .video(let v):
            w.u8(MessageType.video.rawValue)
            w.u8(v.isKeyframe ? 1 : 0)
            w.u32(v.inputAck)
            w.u32(v.ackAgeMicros)
            w.u32(v.encodeMicros)
            w.u64(v.captureMicros)
            w.u8(UInt8(v.parameterSets.count))
            for set in v.parameterSets { w.blob(set) }
            w.data.append(v.payload)
        case .touch(let t):
            w.u8(MessageType.touch.rawValue)
            w.u32(t.id)
            w.u8(t.phase.rawValue)
            w.u32(t.x.bitPattern)
            w.u32(t.y.bitPattern)
        case .requestKeyframe:
            w.u8(MessageType.requestKeyframe.rawValue)
        case .ping(let v):
            w.u8(MessageType.ping.rawValue)
            w.u64(v)
        case .pong(let v):
            w.u8(MessageType.pong.rawValue)
            w.u64(v)
        case .key(let k):
            w.u8(MessageType.key.rawValue)
            w.u16(k.usage)
            w.u8(k.down ? 1 : 0)
        case .button(let b):
            w.u8(MessageType.button.rawValue)
            w.u8(b.button.rawValue)
            w.u8(b.down ? 1 : 0)
        case .orientation(let o):
            w.u8(MessageType.orientation.rawValue)
            w.u8(o.rawValue)
        case .installBegin(let name, let size):
            w.u8(MessageType.installBegin.rawValue)
            w.string(name)
            w.u64(size)
        case .installChunk(let data):
            w.u8(MessageType.installChunk.rawValue)
            w.data.append(data)
        case .installEnd:
            w.u8(MessageType.installEnd.rawValue)
        case .installStatus(let s):
            w.u8(MessageType.installStatus.rawValue)
            w.u8(s.state.rawValue)
            w.string(s.message)
        case .streamConfig(let c):
            w.u8(MessageType.streamConfig.rawValue)
            w.u8(c.video.rawValue)
        case .frameInfo(let f):
            w.u8(MessageType.frameInfo.rawValue)
            w.u32(f.rtpTimestamp)
            w.u8(f.isKeyframe ? 1 : 0)
            w.u32(f.inputAck)
            w.u32(f.ackAgeMicros)
            w.u32(f.encodeMicros)
        case .videoChunk(let c):
            w.u8(MessageType.videoChunk.rawValue)
            w.u32(c.frame)
            w.u16(c.index)
            w.u16(c.count)
            w.data.append(c.bytes)
        }
        let length = UInt32(w.data.count - 4).bigEndian
        withUnsafeBytes(of: length) { w.data.replaceSubrange(0..<4, with: $0) }
        return w.data
    }

    /// The message without its length prefix: one data channel message.
    public func encodedBody() -> Data { encoded().dropFirst(4) }

    /// Parses one message body (type byte + payload, without the length prefix).
    public init(body: Data) throws {
        var r = Reader(body)
        let rawType = try r.u8()
        guard let type = MessageType(rawValue: rawType) else { throw SimStreamError.unknownType(rawType) }
        switch type {
        case .hello:
            self = .hello(Hello(
                version: try r.u16(), screenWidth: try r.u32(), screenHeight: try r.u32(),
                videoWidth: try r.u32(), videoHeight: try r.u32(), codec: try r.u32(),
                deviceID: try r.string(), deviceName: try r.string()
            ))
        case .video:
            let flags = try r.u8()
            let inputAck = try r.u32()
            let ackAge = try r.u32()
            let encode = try r.u32()
            let capture = try r.u64()
            let count = try r.u8()
            var sets: [Data] = []
            for _ in 0..<count { sets.append(try r.blob()) }
            self = .video(VideoFrame(
                isKeyframe: flags & 1 != 0, inputAck: inputAck, ackAgeMicros: ackAge, encodeMicros: encode,
                captureMicros: capture, parameterSets: sets, payload: r.rest()
            ))
        case .touch:
            let id = try r.u32()
            let rawPhase = try r.u8()
            guard let phase = Touch.Phase(rawValue: rawPhase) else { throw SimStreamError.badValue("touch phase \(rawPhase)") }
            self = .touch(Touch(id: id, phase: phase, x: Float(bitPattern: try r.u32()), y: Float(bitPattern: try r.u32())))
        case .requestKeyframe:
            self = .requestKeyframe
        case .ping:
            self = .ping(try r.u64())
        case .pong:
            self = .pong(try r.u64())
        case .key:
            self = .key(KeyEvent(usage: try r.u16(), down: try r.u8() != 0))
        case .button:
            let raw = try r.u8()
            guard let button = ButtonEvent.Button(rawValue: raw) else { throw SimStreamError.badValue("button \(raw)") }
            self = .button(ButtonEvent(button: button, down: try r.u8() != 0))
        case .orientation:
            let raw = try r.u8()
            guard let o = Orientation(rawValue: raw) else { throw SimStreamError.badValue("orientation \(raw)") }
            self = .orientation(o)
        case .installBegin:
            self = .installBegin(name: try r.string(), size: try r.u64())
        case .installChunk:
            self = .installChunk(r.rest())
        case .installEnd:
            self = .installEnd
        case .installStatus:
            let raw = try r.u8()
            guard let state = InstallStatus.State(rawValue: raw) else { throw SimStreamError.badValue("install state \(raw)") }
            self = .installStatus(InstallStatus(state: state, message: try r.string()))
        case .streamConfig:
            let raw = try r.u8()
            guard let video = StreamConfig.VideoTransport(rawValue: raw) else { throw SimStreamError.badValue("video transport \(raw)") }
            self = .streamConfig(StreamConfig(video: video))
        case .frameInfo:
            self = .frameInfo(FrameInfo(
                rtpTimestamp: try r.u32(), isKeyframe: try r.u8() & 1 != 0, inputAck: try r.u32(),
                ackAgeMicros: try r.u32(), encodeMicros: try r.u32()
            ))
        case .videoChunk:
            self = .videoChunk(VideoChunk(frame: try r.u32(), index: try r.u16(), count: try r.u16(), bytes: r.rest()))
        }
        guard r.isAtEnd else { throw SimStreamError.badValue("trailing bytes in \(type)") }
    }
}

/// Reassembles messages from a byte stream that arrives in arbitrary chunks.
public struct MessageReader: Sendable {
    private var buffer = Data()
    private var offset = 0

    public init() {}

    /// Appends bytes from the socket and returns every message that is now complete.
    public mutating func append(_ chunk: Data) throws -> [SimStreamMessage] {
        buffer.append(chunk)
        var messages: [SimStreamMessage] = []
        while buffer.count - offset >= 4 {
            let start = buffer.startIndex + offset
            let length = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
            guard length >= 1, length <= SimStream.maxMessageSize else { throw SimStreamError.messageTooLarge(length) }
            guard buffer.count - offset - 4 >= length else { break }
            messages.append(try SimStreamMessage(body: buffer[start + 4..<start + 4 + length]))
            offset += 4 + length
        }
        // Drop consumed bytes once they dominate the buffer, so a long stream stays O(n).
        if offset > 0, offset >= buffer.count / 2 {
            buffer.removeSubrange(buffer.startIndex..<buffer.startIndex + offset)
            offset = 0
        }
        return messages
    }

    /// Bytes received but not yet part of a complete message.
    public var pendingBytes: Int { buffer.count - offset }
}

// MARK: - Primitives

private struct Writer {
    var data = Data()
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func blob(_ v: Data) {
        u16(UInt16(clamping: v.count))
        data.append(v.prefix(Int(UInt16.max)))
    }
    mutating func string(_ v: String) { blob(Data(v.utf8)) }
}

private struct Reader {
    private let data: Data
    private var index: Data.Index

    init(_ data: Data) {
        self.data = data
        index = data.startIndex
    }

    var isAtEnd: Bool { index == data.endIndex }

    private mutating func take(_ n: Int) throws -> Data {
        guard data.endIndex - index >= n else { throw SimStreamError.truncated }
        defer { index += n }
        return data[index..<index + n]
    }

    private mutating func integer<T: FixedWidthInteger>(_: T.Type) throws -> T {
        try take(MemoryLayout<T>.size).reduce(0) { $0 << 8 | T($1) }
    }

    mutating func u8() throws -> UInt8 { try integer(UInt8.self) }
    mutating func u16() throws -> UInt16 { try integer(UInt16.self) }
    mutating func u32() throws -> UInt32 { try integer(UInt32.self) }
    mutating func u64() throws -> UInt64 { try integer(UInt64.self) }
    mutating func blob() throws -> Data { Data(try take(Int(try u16()))) }

    mutating func string() throws -> String {
        guard let s = String(data: try blob(), encoding: .utf8) else { throw SimStreamError.badValue("string is not UTF-8") }
        return s
    }

    mutating func rest() -> Data {
        defer { index = data.endIndex }
        return Data(data[index...])
    }
}
