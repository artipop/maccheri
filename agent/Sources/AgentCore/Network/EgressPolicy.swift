import Darwin
import Foundation

/// Which destinations the guest may reach: the public internet only. Everything the owner's Mac
/// can see locally (RFC 1918 networks, link-local, CGNAT ranges used by Tailscale and carriers,
/// loopback, multicast, the Mac's own addresses) is refused, so a job can't scan or attack the
/// owner's home network or services listening on the host.
public struct EgressPolicy: Sendable {
    public struct Range: Sendable, Equatable, CustomStringConvertible {
        public var network: IPv4
        public var prefix: Int

        public init(_ network: IPv4, _ prefix: Int) {
            self.network = network
            self.prefix = prefix
        }

        public init?(_ cidr: String) {
            let parts = cidr.split(separator: "/")
            guard parts.count == 2, let network = IPv4(String(parts[0])), let prefix = Int(parts[1]), (0...32).contains(prefix) else { return nil }
            self.init(network, prefix)
        }

        public func contains(_ address: IPv4) -> Bool {
            guard prefix > 0 else { return true }
            let mask: UInt32 = prefix == 32 ? .max : ~(UInt32.max >> prefix)
            return address.value & mask == network.value & mask
        }

        public var description: String { "\(network)/\(prefix)" }
    }

    /// IANA special-purpose IPv4 ranges (RFC 6890) that are not the public internet.
    public static let nonPublic: [Range] = [
        "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16", "172.16.0.0/12",
        "192.0.0.0/24", "192.0.2.0/24", "192.88.99.0/24", "192.168.0.0/16", "198.18.0.0/15",
        "198.51.100.0/24", "203.0.113.0/24", "224.0.0.0/4", "240.0.0.0/4",
    ].map { Range($0)! }

    public var blocked: [Range]
    /// Exceptions to ``blocked``; tests use it to reach a server on loopback.
    public var allowed: [Range]
    /// Also refuse the host's own interface addresses (a Mac with a public IP is still the host).
    public var blocksHostAddresses: Bool

    public init(blocked: [Range] = EgressPolicy.nonPublic, allowed: [Range] = [], blocksHostAddresses: Bool = true) {
        self.blocked = blocked
        self.allowed = allowed
        self.blocksHostAddresses = blocksHostAddresses
    }

    public static let internetOnly = EgressPolicy()

    public func permits(_ address: IPv4) -> Bool {
        if allowed.contains(where: { $0.contains(address) }) { return true }
        if blocked.contains(where: { $0.contains(address) }) { return false }
        if blocksHostAddresses, HostAddresses.current().contains(address) { return false }
        return true
    }
}

/// The host's IPv4 interface addresses, cached briefly: they change when Wi-Fi or a VPN does.
enum HostAddresses {
    nonisolated(unsafe) private static var cache: (time: ContinuousClock.Instant, addresses: Set<IPv4>)?
    private static let lock = NSLock()

    static func current() -> Set<IPv4> {
        lock.lock()
        defer { lock.unlock() }
        let now = ContinuousClock.now
        if let cache, now - cache.time < .seconds(5) { return cache.addresses }
        let addresses = read()
        cache = (now, addresses)
        return addresses
    }

    private static func read() -> Set<IPv4> {
        var result = Set<IPv4>()
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return result }
        defer { freeifaddrs(list) }
        var entry = list
        while let current = entry {
            if let address = current.pointee.ifa_addr, address.pointee.sa_family == sa_family_t(AF_INET) {
                address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    result.insert(IPv4(UInt32(bigEndian: $0.pointee.sin_addr.s_addr)))
                }
            }
            entry = current.pointee.ifa_next
        }
        return result
    }
}

/// IPv4 name servers the host uses, from `/etc/resolv.conf` (macOS keeps it in sync with the
/// primary resolver). Guests send DNS to the gateway; the agent asks these on their behalf, so the
/// guest never talks to the owner's router directly.
enum HostResolvers {
    static func current() -> [IPv4] {
        let text = (try? String(contentsOfFile: "/etc/resolv.conf", encoding: .utf8)) ?? ""
        let servers = text.split(separator: "\n").compactMap { line -> IPv4? in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count >= 2, fields[0] == "nameserver" else { return nil }
            return IPv4(String(fields[1]))
        }
        return servers.isEmpty ? [IPv4(1, 1, 1, 1)] : servers
    }
}
