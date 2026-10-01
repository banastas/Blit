// The connection a mounted SMB share actually runs over (PRD R1.7). macOS
// keeps a share's connection on the interface it was made on, so a share that
// connected, or reconnected after a drop, while only Wi-Fi was up stays on
// Wi-Fi once the cable is back, though new connections take the cable (which
// is all NetworkPath sees). Found when a laptop's copy to the NAS crawled at
// 0–9 MB/s with a gigabit cable plugged in.
//
// The session's server address comes from `smbutil multichannel`, then the
// interface of the TCP connection to it from `nettop` (the connection is the
// kernel's own, so no process lists it, and netstat cuts IPv6 addresses short).

import Darwin
import Foundation

public struct SMBConnection: Sendable, Equatable {
    /// The NAS address the session uses: "192.168.20.12", or an IPv6 address.
    public var server: String
    /// The interface its connection runs over ("en7").
    public var interface: String
    public var isWiFi: Bool
    /// SMB multichannel: the session picks its interfaces itself; left alone.
    public var isMultichannel: Bool
    /// The route a new connection to the same address would take.
    public var fresh: NetworkPath?

    public init(server: String, interface: String, isWiFi: Bool, isMultichannel: Bool, fresh: NetworkPath?) {
        self.server = server
        self.interface = interface
        self.isWiFi = isWiFi
        self.isMultichannel = isMultichannel
        self.fresh = fresh
    }

    /// On Wi-Fi while a new connection would take a wired link: reconnecting
    /// the share moves it to the cable.
    public var reconnectMovesToWired: Bool {
        isWiFi && !isMultichannel && fresh.map { !$0.isWiFi } == true
    }

    /// The live connection of the share mounted at `mountPoint`; nil when it
    /// isn't an SMB mount or the tools don't say. Runs two tools (about 0.1 s,
    /// longer on a share that stopped answering): call it off the main thread.
    public static func of(mountPoint: String) -> SMBConnection? {
        guard let session = server(ofMountPoint: mountPoint),
              let flows = run("/usr/bin/nettop", ["-m", "tcp", "-L", "1", "-n", "-x"]),
              let interface = interface(to: session.server, port: 445, in: flows) else { return nil }
        return SMBConnection(server: session.server, interface: interface,
                             isWiFi: NetworkPath.wifiInterfaceNames().contains(interface),
                             isMultichannel: session.multichannel, fresh: NetworkPath.to(address: session.server))
    }

    /// The server address the share mounted at `mountPoint` is connected to.
    public static func server(ofMountPoint mountPoint: String) -> (server: String, multichannel: Bool)? {
        run("/usr/bin/smbutil", ["multichannel", "-m", mountPoint]).flatMap(parseSession)
    }

    /// Whether two addresses are the same, however each is written.
    public static func sameAddress(_ a: String, _ b: String) -> Bool {
        guard let x = addressBytes(a) else { return false }
        return x == addressBytes(b)
    }

    // MARK: - Reading the tools' output

    /// The server address and multichannel flag from `smbutil multichannel -m`:
    ///
    ///     Info: Setup Time: …, Multichannel ON: no, Reconnect Count: 0
    ///            id   client IF   server IF   state                 server ip       port   speed
    ///     ==================================================================================
    ///     M       0   N/A         N/A         [session active   ]   192.168.20.12   445    N/A
    static func parseSession(_ text: String) -> (server: String, multichannel: Bool)? {
        let multichannel = text.range(of: "Multichannel ON: yes", options: .caseInsensitive) != nil
        var pastRule = false
        for line in text.split(separator: "\n") {
            if line.hasPrefix("====") { pastRule = true; continue }
            guard pastRule else { continue }
            if let address = line.split(whereSeparator: \.isWhitespace).map(String.init).first(where: { addressBytes($0) != nil }) {
                return (address, multichannel)
            }
        }
        return nil
    }

    /// The interface of the established TCP connection to `server`:`port`
    /// in `nettop -m tcp -L 1 -n -x` output: CSV lines of time, flow,
    /// interface and state, the flow written "tcp4 192.168.20.86:57851<->
    /// 192.168.20.12:445" or "tcp6 fd66::1.51234<->fd66::2.445".
    static func interface(to server: String, port: UInt16, in nettop: String) -> String? {
        guard let target = addressBytes(server) else { return nil }
        for line in nettop.split(separator: "\n") {
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count > 3, fields[3] == "Established", !fields[2].isEmpty,
                  let arrow = fields[1].range(of: "<->"),
                  let remote = endpoint(fields[1][arrow.upperBound...]),
                  remote.port == port, addressBytes(remote.address) == target else { continue }
            return String(fields[2])
        }
        return nil
    }

    /// "192.168.20.12:445" or "fd66::2%en0.445": the address (scope left out) and port.
    static func endpoint(_ text: Substring) -> (address: String, port: UInt16)? {
        let isIPv6 = text.filter { $0 == ":" }.count > 1
        guard let cut = text.lastIndex(of: isIPv6 ? "." : ":"),
              let port = UInt16(text[text.index(after: cut)...]) else { return nil }
        var address = text[..<cut]
        if let scope = address.firstIndex(of: "%") { address = address[..<scope] }
        return (address.trimmingCharacters(in: CharacterSet(charactersIn: "[]")), port)
    }

    /// An address's bytes (IPv4 or IPv6), to compare however it's written.
    static func addressBytes(_ text: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, text, &v4) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, text, &v6) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
        return nil
    }

    // MARK: - Running the tools

    private final class Output: @unchecked Sendable {
        var data = Data()   // written by the reader, read once it signals
    }

    /// A tool's output, or nil if it fails or runs longer than `timeout`
    /// (smbutil can wait on a share that stopped answering).
    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 5) -> String? {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let output = Output(), finished = DispatchSemaphore(value: 0)
        let reader = pipe.fileHandleForReading
        DispatchQueue.global().async {
            output.data = reader.readDataToEndOfFile()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()   // closes its end of the pipe, which ends the read
            _ = finished.wait(timeout: .now() + 2)
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: output.data, as: UTF8.self)
    }
}
