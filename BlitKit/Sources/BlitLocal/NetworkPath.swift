// Which interface macOS uses to reach a host, and whether that's Wi-Fi while a
// wired interface is up (PRD R1.7). In the reference setup, Wi-Fi sat on the
// NAS's subnet and the wired port didn't, silently halving SSD → NAS speed.

import Darwin
import Foundation
import SystemConfiguration

public struct NetworkPath: Sendable, Equatable {
    public var interface: String
    public var localAddress: String
    public var isWiFi: Bool
    /// Wired interfaces that are up with an IPv4 address.
    public var activeWired: [String]

    /// True when traffic would go over Wi-Fi even though a wired link is available.
    public var wifiDespiteWired: Bool { isWiFi && !activeWired.isEmpty }

    /// The route macOS would pick to `host` (IPv4). Connecting a UDP socket
    /// selects a route without sending anything.
    public static func to(host: String, port: UInt16 = 445) -> NetworkPath? {
        guard let remote = ipv4(host) else { return nil }
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = remote
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        let localIP = String(cString: inet_ntoa(local.sin_addr))
        let interfaces = ipv4Interfaces()
        guard let name = interfaces.first(where: { $0.address == localIP })?.name else { return nil }
        let wifi = wifiInterfaceNames()
        let wired = Set(interfaces.map(\.name)).filter { ethernetInterfaceNames().contains($0) }.sorted()
        return NetworkPath(interface: name, localAddress: localIP, isWiFi: wifi.contains(name), activeWired: wired)
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
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return [] }
        defer { freeifaddrs(list) }
        var result: [(String, String)] = []
        var cursor = list
        while let entry = cursor?.pointee {
            defer { cursor = entry.ifa_next }
            let flags = Int32(entry.ifa_flags)
            guard let addr = entry.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_RUNNING != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { String(cString: inet_ntoa($0.pointee.sin_addr)) }
            result.append((String(cString: entry.ifa_name), ip))
        }
        return result
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
