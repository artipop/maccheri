import Foundation

/// An IPv4 address in host byte order.
public struct IPv4: Hashable, Sendable, Comparable, CustomStringConvertible {
    public var value: UInt32

    public init(_ value: UInt32) { self.value = value }

    public init(_ a: UInt8, _ b: UInt8, _ c: UInt8, _ d: UInt8) {
        value = UInt32(a) << 24 | UInt32(b) << 16 | UInt32(c) << 8 | UInt32(d)
    }

    public init?(_ string: String) {
        let parts = string.split(separator: ".", omittingEmptySubsequences: false).map { UInt8($0) }
        guard parts.count == 4, let a = parts[0], let b = parts[1], let c = parts[2], let d = parts[3] else { return nil }
        self.init(a, b, c, d)
    }

    public static let any = IPv4(0)
    public static let broadcast = IPv4(0xFFFF_FFFF)

    public var description: String { "\(value >> 24).\(value >> 16 & 0xFF).\(value >> 8 & 0xFF).\(value & 0xFF)" }
    public static func < (lhs: IPv4, rhs: IPv4) -> Bool { lhs.value < rhs.value }

    var sockaddr: sockaddr_in {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = value.bigEndian
        return address
    }
}

public struct MACAddress: Hashable, Sendable, CustomStringConvertible {
    public var bytes: [UInt8]

    public init(_ bytes: [UInt8]) {
        precondition(bytes.count == 6)
        self.bytes = bytes
    }

    /// `"aa:bb:cc:dd:ee:ff"`, as `VZMACAddress.string` prints it.
    public init?(_ string: String) {
        let parts = string.split(separator: ":").map { UInt8($0, radix: 16) }
        guard parts.count == 6, parts.allSatisfy({ $0 != nil }) else { return nil }
        self.init(parts.map { $0! })
    }

    public static let broadcast = MACAddress([0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF])
    public var description: String { bytes.map { String(format: "%02x", $0) }.joined(separator: ":") }
}

// MARK: - Byte access

extension Array where Element == UInt8 {
    @inline(__always) func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) << 8 | UInt16(self[offset + 1]) }
    @inline(__always) func u32(_ offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 | UInt32(self[offset + 1]) << 16 | UInt32(self[offset + 2]) << 8 | UInt32(self[offset + 3])
    }
    @inline(__always) mutating func put16(_ value: UInt16, at offset: Int) {
        self[offset] = UInt8(value >> 8)
        self[offset + 1] = UInt8(value & 0xFF)
    }
    @inline(__always) mutating func put32(_ value: UInt32, at offset: Int) {
        self[offset] = UInt8(value >> 24)
        self[offset + 1] = UInt8(value >> 16 & 0xFF)
        self[offset + 2] = UInt8(value >> 8 & 0xFF)
        self[offset + 3] = UInt8(value & 0xFF)
    }
}

/// RFC 1071 one's-complement sum, folded later by ``finishChecksum(_:)``.
func checksumSum<C: Collection>(_ bytes: C, initial: UInt32 = 0) -> UInt32 where C.Element == UInt8 {
    var sum = initial
    var iterator = bytes.makeIterator()
    while let high = iterator.next() {
        let low = iterator.next() ?? 0
        sum &+= UInt32(high) << 8 | UInt32(low)
    }
    return sum
}

func finishChecksum(_ sum: UInt32) -> UInt16 {
    var sum = sum
    while sum >> 16 != 0 { sum = (sum & 0xFFFF) + (sum >> 16) }
    return ~UInt16(sum)
}

// MARK: - Layouts

enum EtherType {
    static let ipv4: UInt16 = 0x0800
    static let arp: UInt16 = 0x0806
}

enum IPProtocolNumber {
    static let icmp: UInt8 = 1
    static let tcp: UInt8 = 6
    static let udp: UInt8 = 17
}

struct TCPFlags: OptionSet, Sendable {
    let rawValue: UInt8
    static let fin = TCPFlags(rawValue: 0x01)
    static let syn = TCPFlags(rawValue: 0x02)
    static let rst = TCPFlags(rawValue: 0x04)
    static let psh = TCPFlags(rawValue: 0x08)
    static let ack = TCPFlags(rawValue: 0x10)
}

/// An IPv4 packet the guest sent, already stripped of its Ethernet header.
struct IPv4Packet {
    var bytes: [UInt8]
    var headerLength: Int
    var totalLength: Int
    var proto: UInt8
    var source: IPv4
    var destination: IPv4

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= 20, bytes[0] >> 4 == 4 else { return nil }
        let headerLength = Int(bytes[0] & 0x0F) * 4
        let totalLength = Int(bytes.u16(2))
        guard headerLength >= 20, totalLength >= headerLength, totalLength <= bytes.count else { return nil }
        // Fragments: guests send with DF set and a 1500-byte MTU, so drop the rare exception.
        let fragment = bytes.u16(6)
        guard fragment & 0x2000 == 0, fragment & 0x1FFF == 0 else { return nil }
        self.bytes = bytes
        self.headerLength = headerLength
        self.totalLength = totalLength
        proto = bytes[9]
        source = IPv4(bytes.u32(12))
        destination = IPv4(bytes.u32(16))
    }

    var payload: ArraySlice<UInt8> { bytes[headerLength..<totalLength] }
}

struct TCPSegment {
    var sourcePort: UInt16
    var destinationPort: UInt16
    var seq: UInt32
    var ack: UInt32
    var flags: TCPFlags
    var window: UInt16
    var payload: ArraySlice<UInt8>
    /// From SYN options.
    var mss: UInt16?
    var windowScale: UInt8?

    init?(_ bytes: ArraySlice<UInt8>) {
        let b = Array(bytes)
        guard b.count >= 20 else { return nil }
        let dataOffset = Int(b[12] >> 4) * 4
        guard dataOffset >= 20, dataOffset <= b.count else { return nil }
        sourcePort = b.u16(0)
        destinationPort = b.u16(2)
        seq = b.u32(4)
        ack = b.u32(8)
        flags = TCPFlags(rawValue: b[13] & 0x3F)
        window = b.u16(14)
        payload = bytes[(bytes.startIndex + dataOffset)...]
        var i = 20
        while i < dataOffset {
            let kind = b[i]
            if kind == 0 { break }
            if kind == 1 { i += 1; continue }
            guard i + 1 < dataOffset else { break }
            let length = Int(b[i + 1])
            guard length >= 2, i + length <= dataOffset else { break }
            if kind == 2, length == 4 { mss = b.u16(i + 2) }
            if kind == 3, length == 3 { windowScale = b[i + 2] }
            i += length
        }
    }
}

struct UDPDatagram {
    var sourcePort: UInt16
    var destinationPort: UInt16
    var payload: ArraySlice<UInt8>

    init?(_ bytes: ArraySlice<UInt8>) {
        guard bytes.count >= 8 else { return nil }
        let s = bytes.startIndex
        sourcePort = UInt16(bytes[s]) << 8 | UInt16(bytes[s + 1])
        destinationPort = UInt16(bytes[s + 2]) << 8 | UInt16(bytes[s + 3])
        let length = Int(UInt16(bytes[s + 4]) << 8 | UInt16(bytes[s + 5]))
        guard length >= 8, length <= bytes.count else { return nil }
        payload = bytes[(s + 8)..<(s + length)]
    }
}

// MARK: - Building frames for the guest

enum FrameBuilder {
    static func ethernet(to destination: MACAddress, from source: MACAddress, type: UInt16, payload: [UInt8]) -> [UInt8] {
        var frame = destination.bytes + source.bytes + [UInt8(type >> 8), UInt8(type & 0xFF)]
        frame.append(contentsOf: payload)
        return frame
    }

    static func ipv4(from source: IPv4, to destination: IPv4, proto: UInt8, payload: [UInt8], id: UInt16 = 0) -> [UInt8] {
        var header = [UInt8](repeating: 0, count: 20)
        header[0] = 0x45
        header.put16(UInt16(20 + payload.count), at: 2)
        header.put16(id, at: 4)
        header.put16(0x4000, at: 6) // DF
        header[8] = 64
        header[9] = proto
        header.put32(source.value, at: 12)
        header.put32(destination.value, at: 16)
        header.put16(finishChecksum(checksumSum(header)), at: 10)
        return header + payload
    }

    private static func pseudoHeaderSum(source: IPv4, destination: IPv4, proto: UInt8, length: Int) -> UInt32 {
        var sum: UInt32 = 0
        sum &+= source.value >> 16
        sum &+= source.value & 0xFFFF
        sum &+= destination.value >> 16
        sum &+= destination.value & 0xFFFF
        sum &+= UInt32(proto)
        sum &+= UInt32(length)
        return sum
    }

    static func udp(from source: IPv4, port sourcePort: UInt16, to destination: IPv4, port destinationPort: UInt16, payload: some Collection<UInt8>) -> [UInt8] {
        var segment = [UInt8](repeating: 0, count: 8)
        segment.put16(sourcePort, at: 0)
        segment.put16(destinationPort, at: 2)
        segment.put16(UInt16(8 + payload.count), at: 4)
        segment.append(contentsOf: payload)
        var checksum = finishChecksum(checksumSum(segment, initial: pseudoHeaderSum(source: source, destination: destination, proto: IPProtocolNumber.udp, length: segment.count)))
        if checksum == 0 { checksum = 0xFFFF }
        segment.put16(checksum, at: 6)
        return ipv4(from: source, to: destination, proto: IPProtocolNumber.udp, payload: segment)
    }

    static func tcp(
        from source: IPv4, port sourcePort: UInt16, to destination: IPv4, port destinationPort: UInt16,
        seq: UInt32, ack: UInt32, flags: TCPFlags, window: UInt16,
        mss: UInt16? = nil, windowScale: UInt8? = nil, payload: some Collection<UInt8> = [UInt8]()
    ) -> [UInt8] {
        var options: [UInt8] = []
        if let mss { options += [2, 4, UInt8(mss >> 8), UInt8(mss & 0xFF)] }
        if let windowScale { options += [1, 3, 3, windowScale] }
        let headerLength = 20 + options.count
        var segment = [UInt8](repeating: 0, count: 20)
        segment.reserveCapacity(headerLength + payload.count)
        segment.put16(sourcePort, at: 0)
        segment.put16(destinationPort, at: 2)
        segment.put32(seq, at: 4)
        segment.put32(ack, at: 8)
        segment[12] = UInt8(headerLength / 4) << 4
        segment[13] = flags.rawValue
        segment.put16(window, at: 14)
        segment.append(contentsOf: options)
        segment.append(contentsOf: payload)
        let sum = checksumSum(segment, initial: pseudoHeaderSum(source: source, destination: destination, proto: IPProtocolNumber.tcp, length: segment.count))
        segment.put16(finishChecksum(sum), at: 16)
        return ipv4(from: source, to: destination, proto: IPProtocolNumber.tcp, payload: segment)
    }

    static func icmp(from source: IPv4, to destination: IPv4, message: [UInt8]) -> [UInt8] {
        var message = message
        message[2] = 0
        message[3] = 0
        message.put16(finishChecksum(checksumSum(message)), at: 2)
        return ipv4(from: source, to: destination, proto: IPProtocolNumber.icmp, payload: message)
    }
}
