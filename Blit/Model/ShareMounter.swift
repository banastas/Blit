// Reconnecting NAS shares (PRD R1.5). Blit remembers how each SMB share was
// mounted (its smb:// address, never a password) and remounts it with NetFS
// without any UI; macOS supplies the password it saved in the Keychain when
// the share was first connected in Finder. Used when a queued transfer waits
// on a share, when an unavailable favorite is opened, and from the sidebar's
// Reconnect item.

import AppKit
import BlitLocal
import Foundation
import NetFS
import Security

@MainActor
enum ShareMounter {
    private static let key = "knownShares"   // mount point → smb:// address

    private static var known: [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    /// Notes how a mounted SMB share was mounted (from the sidebar's volume scan).
    static func remember(mountPoint: String) {
        // From the mount table, never statfs: a hung share would block the main thread.
        guard let info = MountInfo.mounted(at: mountPoint), info.isSMB, info.source.hasPrefix("//") else { return }
        var all = known
        let address = "smb:" + info.source
        guard all[mountPoint] != address else { return }
        all[mountPoint] = address
        UserDefaults.standard.set(all, forKey: key)
    }

    /// The known share (its mount point, "/Volumes/Media") that `path` is on,
    /// when that share isn't mounted right now.
    static func missingShare(containing path: String) -> String? {
        let parts = URL(filePath: path).lexicalComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return nil }
        let mountPoint = "/Volumes/" + parts[2]
        guard known[mountPoint] != nil, !isMounted(mountPoint) else { return nil }
        return mountPoint
    }

    static func isKnown(_ mountPoint: String) -> Bool { known[mountPoint] != nil }

    private static func isMounted(_ mountPoint: String) -> Bool {
        MountInfo.mounted(at: mountPoint) != nil
    }

    /// Remounts the share last mounted at `mountPoint`. Returns a problem to
    /// show, or nil once it's mounted there.
    static func reconnect(_ mountPoint: String) async -> String? {
        if isMounted(mountPoint) { return nil }
        guard let address = known[mountPoint], let url = URL(string: address) else {
            return "Blit doesn't know how \(mountPoint) was connected. Connect it once in Finder (Go › Connect to Server)."
        }
        let status = await Task.detached { () -> Int32 in
            let open = NSMutableDictionary()
            open[kNAUIOptionKey] = kNAUIOptionNoUI   // never show a dialog
            var mounts: Unmanaged<CFArray>?
            let result = NetFSMountURLSync(url as CFURL, nil, nil, nil, open, nil, &mounts)
            mounts?.release()
            return result
        }.value
        let name = (mountPoint as NSString).lastPathComponent
        // EEXIST: it was already mounted (by Finder or another app meanwhile).
        guard status == 0 || status == EEXIST else {
            switch status {
            case EAUTH, EACCES, EPERM, -6003:
                return "Couldn't reconnect “\(name)”: macOS has no saved password for it. Connect it once in Finder (Go › Connect to Server) and choose Remember this password."
            case ENETUNREACH, EHOSTUNREACH, ETIMEDOUT, EHOSTDOWN, ENOENT:
                return "Couldn't reach the NAS for “\(name)”. Check that it's on and on the network."
            default:
                return "Couldn't reconnect “\(name)” (error \(status)). Connect it in Finder (Go › Connect to Server)."
            }
        }
        guard isMounted(mountPoint) else {
            return "“\(name)” reconnected, but macOS mounted it somewhere else. Eject the other copy and reconnect."
        }
        return nil
    }

    /// Whether macOS has the password saved for the share mounted at
    /// `mountPoint` (Finder's Remember this password), so remounting it
    /// without a dialog works. Reads the Keychain item's attributes, never
    /// the password, so it never asks.
    static func hasSavedPassword(_ mountPoint: String) -> Bool {
        guard let address = known[mountPoint], let parts = URLComponents(string: address), let host = parts.host else { return false }
        var query: [CFString: Any] = [kSecClass: kSecClassInternetPassword, kSecAttrServer: host,
                                      kSecAttrProtocol: kSecAttrProtocolSMB, kSecMatchLimit: kSecMatchLimitOne,
                                      kSecReturnAttributes: true]
        if let user = parts.user, !user.isEmpty { query[kSecAttrAccount] = user }
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    /// Ejects the share as Finder does, never forced: macOS refuses while
    /// anything has a file open on it. Returns why, or nil once it's ejected.
    static func eject(_ mountPoint: String) async -> String? {
        do {
            try await FileManager.default.unmountVolume(at: URL(filePath: mountPoint, directoryHint: .isDirectory), options: [.withoutUI])
            return nil
        } catch {
            if let pid = (error as NSError).userInfo[NSFileManagerUnmountDissentingProcessIdentifierErrorKey] as? NSNumber,
               let app = NSRunningApplication(processIdentifier: pid.int32Value)?.localizedName {
                return "\(app) is using it"
            }
            return error.localizedDescription
        }
    }

    #if DEBUG
    /// Test copies: the raw NetFS result for a known share, mounted or not
    /// (an already-mounted share answers EEXIST), and its address with the
    /// user name removed.
    static func debugMount(_ mountPoint: String) async -> (status: Int32, address: String) {
        guard let address = known[mountPoint], let url = URL(string: address) else { return (-1, "unknown") }
        let status = await Task.detached { () -> Int32 in
            let open = NSMutableDictionary()
            open[kNAUIOptionKey] = kNAUIOptionNoUI
            var mounts: Unmanaged<CFArray>?
            let result = NetFSMountURLSync(url as CFURL, nil, nil, nil, open, nil, &mounts)
            mounts?.release()
            return result
        }.value
        let shown = address.replacingOccurrences(of: #"//[^@/]+@"#, with: "//…@", options: .regularExpression)
        return (status, shown)
    }
    #endif
}
