import Foundation
import Testing
@testable import SimStreamProtocol

let samples: [SimStreamMessage] = [
    .hello(Hello(screenWidth: 1206, screenHeight: 2622, videoWidth: 603, videoHeight: 1311, codec: 0x6176_6331, deviceID: "1856F703-8191-4583-9C4C-E646B81F46BE", deviceName: "iPhone 17 Pro · пробник")),
    .video(VideoFrame(isKeyframe: true, inputAck: 7, ackAgeMicros: 12_345, encodeMicros: 6_000, captureMicros: 1 << 40, parameterSets: [Data([0x67, 0x64, 0x00, 0x1f]), Data([0x68, 0xee])], payload: Data((0..<1000).map { UInt8($0 & 0xff) }))),
    .video(VideoFrame(isKeyframe: false, inputAck: 0, payload: Data())),
    .touch(Touch(id: 1, phase: .began, x: 0.25, y: 0.75)),
    .touch(Touch(id: .max, phase: .moved, x: 0, y: 1)),
    .touch(Touch(id: 3, phase: .ended, x: 0.999_9, y: 0.000_1)),
    .requestKeyframe,
    .ping(0xdead_beef_cafe),
    .pong(42),
]

@Test(arguments: samples)
func roundTrip(message: SimStreamMessage) throws {
    var reader = MessageReader()
    #expect(try reader.append(message.encoded()) == [message])
    #expect(reader.pendingBytes == 0)
}

@Test func wireLayoutOfTouch() {
    let bytes = [UInt8](SimStreamMessage.touch(Touch(id: 0x0102_0304, phase: .ended, x: 1, y: 0)).encoded())
    #expect(bytes == [0, 0, 0, 14, 3, 1, 2, 3, 4, 2, 0x3f, 0x80, 0, 0, 0, 0, 0, 0])
}

@Test func reassemblesByteByByte() throws {
    let stream = samples.reduce(Data()) { $0 + $1.encoded() }
    var reader = MessageReader()
    var out: [SimStreamMessage] = []
    for byte in stream { out += try reader.append(Data([byte])) }
    #expect(out == samples)
    #expect(reader.pendingBytes == 0)
}

@Test(arguments: [2, 3, 7, 64, 1001])
func reassemblesArbitraryChunks(chunkSize: Int) throws {
    // Many messages so the reader compacts its buffer several times along the way.
    let messages = (0..<50).flatMap { _ in samples }
    let stream = messages.reduce(Data()) { $0 + $1.encoded() }
    var reader = MessageReader()
    var out: [SimStreamMessage] = []
    var i = 0
    while i < stream.count {
        out += try reader.append(stream[i..<min(i + chunkSize, stream.count)])
        i += chunkSize
    }
    #expect(out == messages)
}

@Test func keepsPartialMessageUntilComplete() throws {
    let data = SimStreamMessage.ping(9).encoded()
    var reader = MessageReader()
    #expect(try reader.append(data.prefix(5)).isEmpty)
    #expect(reader.pendingBytes == 5)
    #expect(try reader.append(data.dropFirst(5)) == [.ping(9)])
}

@Test func rejectsHugeLength() {
    var reader = MessageReader()
    #expect(throws: SimStreamError.messageTooLarge(0x7fff_ffff)) { try reader.append(Data([0x7f, 0xff, 0xff, 0xff, 1])) }
}

@Test func rejectsUnknownType() {
    var reader = MessageReader()
    #expect(throws: SimStreamError.unknownType(99)) { try reader.append(Data([0, 0, 0, 1, 99])) }
}

@Test func rejectsTruncatedBody() {
    // A ping whose length says 5 bytes: type + 4 of the 8 payload bytes.
    var reader = MessageReader()
    #expect(throws: SimStreamError.truncated) { try reader.append(Data([0, 0, 0, 5, 5, 0, 0, 0, 1])) }
}

@Test func rejectsBadPhaseAndTrailingBytes() {
    #expect(throws: SimStreamError.self) { try SimStreamMessage(body: Data([3, 0, 0, 0, 1, 9, 0, 0, 0, 0, 0, 0, 0, 0])) }
    #expect(throws: SimStreamError.self) { try SimStreamMessage(body: Data([4, 0])) }
}
