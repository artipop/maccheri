import Darwin
import Foundation

/// A FIFO of bytes with O(1) amortized removal from the front.
struct ByteQueue {
    private var storage: [UInt8] = []
    private var head = 0

    var count: Int { storage.count - head }
    var isEmpty: Bool { count == 0 }

    mutating func append(contentsOf bytes: some Collection<UInt8>) {
        storage.append(contentsOf: bytes)
    }

    /// `length` bytes starting `offset` bytes after the front.
    func slice(from offset: Int, length: Int) -> ArraySlice<UInt8> {
        storage[(head + offset)..<(head + offset + length)]
    }

    mutating func removeFirst(_ n: Int) {
        head += n
        if head == storage.count {
            storage.removeAll(keepingCapacity: true)
            head = 0
        } else if head > 1 << 16, head > storage.count / 2 {
            storage.removeFirst(head)
            head = 0
        }
    }

    /// Calls `body` with the queued bytes; it returns how many it consumed.
    mutating func drain(_ body: (UnsafeRawBufferPointer) -> Int) {
        guard !isEmpty else { return }
        let consumed = storage.withUnsafeBytes { body(UnsafeRawBufferPointer(rebasing: $0[head...])) }
        if consumed > 0 { removeFirst(consumed) }
    }
}

/// Read and write readiness for one non-blocking socket, delivered on the network queue.
/// Closes the descriptor only after both dispatch sources are cancelled, as GCD requires.
final class SocketWatcher {
    let fd: Int32
    private let read: any DispatchSourceRead
    private let write: any DispatchSourceWrite
    private var reading = false
    private var writing = false
    private var closed = false

    init(fd: Int32, queue: DispatchQueue, onReadable: @escaping () -> Void, onWritable: @escaping () -> Void) {
        self.fd = fd
        read = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        write = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        read.setEventHandler(handler: onReadable)
        write.setEventHandler(handler: onWritable)
        let remaining = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        remaining.pointee = 2
        let cancelled = {
            remaining.pointee -= 1
            if remaining.pointee == 0 {
                remaining.deallocate()
                Darwin.close(fd)
            }
        }
        read.setCancelHandler(handler: cancelled)
        write.setCancelHandler(handler: cancelled)
    }

    func setReading(_ on: Bool) {
        guard !closed, on != reading else { return }
        reading = on
        if on { read.resume() } else { read.suspend() }
    }

    func setWriting(_ on: Bool) {
        guard !closed, on != writing else { return }
        writing = on
        if on { write.resume() } else { write.suspend() }
    }

    /// `reset` makes the kernel send RST instead of FIN.
    func close(reset: Bool = false) {
        guard !closed else { return }
        if reset {
            var linger = Darwin.linger(l_onoff: 1, l_linger: 0)
            setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<Darwin.linger>.size))
        }
        // Suspended sources never run their cancel handlers.
        setReading(true)
        setWriting(true)
        closed = true
        read.cancel()
        write.cancel()
    }

    deinit {
        close()
    }
}

enum SocketOptions {
    static func setNonBlocking(_ fd: Int32) {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    static func set(_ fd: Int32, _ level: Int32, _ name: Int32, _ value: Int32) {
        var value = value
        setsockopt(fd, level, name, &value, socklen_t(MemoryLayout<Int32>.size))
    }

    /// A non-blocking TCP or UDP socket with SIGPIPE off.
    static func makeSocket(type: Int32) -> Int32? {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { return nil }
        setNonBlocking(fd)
        set(fd, SOL_SOCKET, SO_NOSIGPIPE, 1)
        if type == SOCK_STREAM { set(fd, IPPROTO_TCP, TCP_NODELAY, 1) }
        return fd
    }

    /// Starts a non-blocking connect; `true` if it is done or in progress.
    static func connect(_ fd: Int32, to address: IPv4, port: UInt16) -> Bool {
        var sa = address.sockaddr
        sa.sin_port = port.bigEndian
        let result = withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0 || errno == EINPROGRESS
    }

    static func pendingError(_ fd: Int32) -> Int32 {
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
        return error
    }
}
