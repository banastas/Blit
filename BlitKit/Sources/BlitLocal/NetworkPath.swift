// Which interface macOS uses to reach a host, and whether that's Wi-Fi while a
// wired interface is up (PRD R1.7). In the reference setup, Wi-Fi sat on the
// NAS's subnet and the wired port didn't, silently halving SSD → NAS speed.
// This is the route a new connection would take; a mounted share keeps the
// interface it connected on, which SMBConnection reads.

import Darwin
import Foundation
import SystemConfiguration

public struct NetworkPath: Sendable, Equatable {
    public var interface: String
    public var localAddress: String
    public var isWiFi: Bool
    /// Wired interfaces that are up with an IPv4 address.
    public var activeWired: [String]

    public init(interface: String, localAddress: String, isWiFi: Bool, activeWired: [String]) {
        self.interface = interface
        self.localAddress = localAddress
        self.isWiFi = isWiFi
        self.activeWired = activeWired
    }

    /// True when traffic would go over Wi-Fi even though a wired link is available.
    public var wifiDespiteWired: Bool { isWiFi && !activeWired.isEmpty }

    /// The route macOS would pick to `host` (IPv4). Connecting a UDP socket
    /// selects a route without sending anything.
    public static func to(host: String, port: UInt16 = 445) -> NetworkPath? {
        guard let remote = ipv4(host) else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = remote
        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { target in
            withUnsafeBytes(of: &addr) { target.copyMemory(from: $0) }
        }
        return route(to: storage)
    }

    /// The route a new connection to `address` would take: an IPv4 or IPv6
    /// address as text, as an SMB session reports its server.
    public static func to(address: String, port: UInt16 = 445) -> NetworkPath? {
        var hints = addrinfo()
        hints.ai_flags = AI_NUMERICHOST | AI_NUMERICSERV
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(address, String(port), &hints, &result) == 0 else { return nil }
        defer { freeaddrinfo(result) }
        guard let first = result, let remote = first.pointee.ai_addr else { return nil }
        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { target in
            target.copyMemory(from: UnsafeRawBufferPointer(start: remote, count: Int(first.pointee.ai_addrlen)))
        }
        return route(to: storage)
    }

    private static func route(to remote: sockaddr_storage) -> NetworkPath? {
        var remote = remote
        let fd = socket(Int32(remote.ss_family), SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t($0.pointee.sa_len)) }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0,
              let localIP = withUnsafePointer(to: &local, { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { numericHost($0) } }),
              let name = interfaceAddresses().first(where: { $0.address == localIP })?.name else { return nil }
        let wifi = wifiInterfaceNames()
        let wired = Set(ipv4Interfaces().map(\.name)).filter { ethernetInterfaceNames().contains($0) }.sorted()
        return NetworkPath(interface: name, localAddress: localIP, isWiFi: wifi.contains(name), activeWired: wired)
    }

    /// "192.168.20.111" for a host name, if it has an IPv4 address.
    public static func ipv4Address(_ host: String) -> String? {
        ipv4(host).map { String(cString: inet_ntoa($0)) }
    }

    static func ipv4(_ host: String) -> in_addr? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        return first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    }

    /// Up-and-running interfaces with an IPv4 address.
    static func ipv4Interfaces() -> [(name: String, address: String)] {
        interfaceAddresses().filter { !$0.address.contains(":") }
    }

    /// Up-and-running interfaces' addresses, IPv4 and IPv6, as text.
    static func interfaceAddresses() -> [(name: String, address: String)] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var result: [(String, String)] = []
        var cursor = list
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            let flags = Int32(entry.ifa_flags)
            guard let addr = entry.ifa_addr, flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0,
                  let text = numericHost(addr) else { continue }
            result.append((String(cString: entry.ifa_name), text))
        }
        return result
    }

    /// An IPv4 or IPv6 address as text, without an IPv6 scope: getifaddrs
    /// writes a link-local address's scope into the address itself (KAME
    /// style) and getsockname doesn't, so it's left out of both.
    static func numericHost(_ address: UnsafePointer<sockaddr>) -> String? {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            var a = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            return text(of: &a, family: AF_INET, length: INET_ADDRSTRLEN)
        case AF_INET6:
            var a = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee.sin6_addr }
            if a.__u6_addr.__u6_addr8.0 == 0xfe, a.__u6_addr.__u6_addr8.1 & 0xc0 == 0x80 {
                a.__u6_addr.__u6_addr8.2 = 0
                a.__u6_addr.__u6_addr8.3 = 0
            }
            return text(of: &a, family: AF_INET6, length: INET6_ADDRSTRLEN)
        default:
            return nil
        }
    }

    private static func text<T>(of address: inout T, family: Int32, length: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(length))
        guard inet_ntop(family, &address, &buffer, socklen_t(length)) != nil else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static func interfaceNames(ofType type: CFString) -> Set<String> {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        return Set(all.compactMap { i in
            SCNetworkInterfaceGetInterfaceType(i) == type ? SCNetworkInterfaceGetBSDName(i) as String? : nil
        })
    }

    static func wifiInterfaceNames() -> Set<String> { interfaceNames(ofType: kSCNetworkInterfaceTypeIEEE80211) }
    static func ethernetInterfaceNames() -> Set<String> { interfaceNames(ofType: kSCNetworkInterfaceTypeEthernet) }
}
