// The live SMB connection check (PRD R1.7): reading the server from smbutil
// and the interface from nettop, IPv4 and IPv6, and the text-only paths that
// keep the main thread off the disk.

import Foundation
import Testing

@testable import BlitLocal

@Suite struct SMBConnectionTests {
    let session = """
    Session: /Volumes/Files
    Info: Setup Time: 2026-09-30 22:31:31, Multichannel ON: no, Reconnect Count: 0
    \tTotal RX Bytes: 35050 (Packets: 120)
    \tTotal TX Bytes: 12456 (Packets: 120)
           id         client IF             server IF   state                     server ip                 port   speed
    ========================================================================================================================
    M       0     N/A                          N/A      [session active       ]   192.168.20.12             445    N/A
    """

    let flows = """
    time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,tc_mgt,cc_algo,P,C,R,W,arch,
    22:32:03.378187,tcp4 192.168.20.86:63165<->192.168.20.164:445,en7,Established,7061514810,52325281,0,0,0,1.22 ms,,,BE,-,cubic,-,-,-,-,so,
    22:32:03.343208,tcp6 *.445<->*.*,,Listen,,,,,,,,,,-,cubic,-,-,-,-,so,
    22:32:03.395591,tcp4 192.168.20.86:445<->192.168.20.12:50731,en7,Established,1,2,0,0,0,1.22 ms,,,BE,-,cubic,-,-,-,-,so,
    22:32:03.446297,tcp4 192.168.20.38:57851<->192.168.20.12:445,en1,Established,35050,12456,0,0,0,1.53 ms,,,BE,-,cubic,-,-,-,-,so,
    22:32:03.449777,tcp6 fd66:6e3e:3c8:4774::86.57860<->fd66:6e3e:3c8:4774:9209:d0ff:fe0a:bca3.445,en0,Established,1,2,0,0,0,1.91 ms,,,BE,-,cubic,-,-,-,-,so,
    22:32:03.452066,smbd.80651,,,1174897,20821385,0,0,4344,,,,,,,,,,,,
    """

    @Test func readsTheSessionsServerAddress() throws {
        let parsed = try #require(SMBConnection.parseSession(session))
        #expect(parsed.server == "192.168.20.12")
        #expect(!parsed.multichannel)
        let multi = try #require(SMBConnection.parseSession(session.replacingOccurrences(of: "Multichannel ON: no", with: "Multichannel ON: yes")))
        #expect(multi.multichannel)
        #expect(SMBConnection.parseSession("smbutil: no such mount") == nil)
    }

    @Test func findsTheInterfaceOfTheConnectionToTheServer() {
        // The outgoing connection to port 445, not this Mac's own share being used by that address.
        #expect(SMBConnection.interface(to: "192.168.20.12", port: 445, in: flows) == "en1")
        #expect(SMBConnection.interface(to: "192.168.20.164", port: 445, in: flows) == "en7")
        // IPv6, however the address is written.
        #expect(SMBConnection.interface(to: "fd66:6e3e:3c8:4774:9209:d0ff:fe0a:bca3", port: 445, in: flows) == "en0")
        #expect(SMBConnection.interface(to: "fd66:6e3e:03c8:4774:9209:d0ff:fe0a:bca3", port: 445, in: flows) == "en0")
        #expect(SMBConnection.interface(to: "192.168.20.99", port: 445, in: flows) == nil)
    }

    @Test func readsEndpointsOfBothFamilies() {
        #expect(SMBConnection.endpoint("192.168.20.12:445")! == ("192.168.20.12", 445))
        #expect(SMBConnection.endpoint("fe80::9ca8:77ff:fe18:145f%anri0.58783")! == ("fe80::9ca8:77ff:fe18:145f", 58783))
        #expect(SMBConnection.endpoint("*.*") == nil)
        #expect(SMBConnection.sameAddress("fd66::1", "fd66:0:0:0:0:0:0:1"))
        #expect(!SMBConnection.sameAddress("192.168.20.12", "192.168.20.14"))
    }

    @Test func movesToWiredOnlyFromWiFiWithAWiredRoute() {
        let wired = NetworkPath(interface: "en7", localAddress: "192.168.20.86", isWiFi: false, activeWired: ["en7"])
        let wifi = NetworkPath(interface: "en1", localAddress: "192.168.20.38", isWiFi: true, activeWired: ["en7"])
        var connection = SMBConnection(server: "192.168.20.12", interface: "en1", isWiFi: true, isMultichannel: false, fresh: wired)
        #expect(connection.reconnectMovesToWired)
        connection.fresh = wifi            // the cable isn't on the NAS's network: reconnecting wouldn't help
        #expect(!connection.reconnectMovesToWired)
        connection.fresh = wired
        connection.isMultichannel = true   // multichannel picks its own interfaces
        #expect(!connection.reconnectMovesToWired)
        connection = SMBConnection(server: "192.168.20.12", interface: "en7", isWiFi: false, isMultichannel: false, fresh: wired)
        #expect(!connection.reconnectMovesToWired)
    }

    @Test func routeProbeTakesAddressesOfBothFamilies() {
        // Loopback has no interface the probe reports; malformed text isn't an address.
        #expect(NetworkPath.to(address: "127.0.0.1") == nil)
        #expect(NetworkPath.to(address: "::1") == nil)
        #expect(NetworkPath.to(address: "not an address") == nil)
        // Every interface address reads back as text without a scope.
        #expect(NetworkPath.interfaceAddresses().allSatisfy { !$0.address.contains("%") })
    }

    @Test func lexicalPathsNeverAskTheDisk() {
        #expect(LexicalPath.normalize("/Volumes/Media/./a//b/../c/") == "/Volumes/Media/a/c")
        #expect(LexicalPath.normalize("/private/var/folders/x") == "/var/folders/x")
        #expect(LexicalPath.normalize("/private/tmp") == "/tmp")
        #expect(LexicalPath.normalize("/privateer/var") == "/privateer/var")
        #expect(LexicalPath.normalize("/../..") == "/")
        #expect(MountInfo.containing("/private/var/../Users")?.mountPoint == "/")
    }
}
