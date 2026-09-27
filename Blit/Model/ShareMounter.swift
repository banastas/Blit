// Reconnecting NAS shares (PRD R1.5). Blit remembers how each SMB share was
// mounted (its smb:// address, never a password) and remounts it with NetFS
// without any UI; macOS supplies the password it saved in the Keychain when
// the share was first connected in Finder. Used when a queued transfer waits
// on a share, when an unavailable favorite is opened, and from the sidebar's
// Reconnect item.

import BlitLocal
import Foundation
import NetFS

@MainActor
enum ShareMounter {
    private static let key = "knownShares"   // mount point → smb:// address

    private static var known: [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    /// Notes how a mounted SMB share was mounted (from the sidebar's volume scan).
    static func remember(mountPoint: String) {
        guard let info = MountInfo.of(mountPoint), info.isSMB, info.mountPoint == mountPoint,
              info.source.hasPrefix("//") else { return }
        var all = known
        let address = "smb:" + info.source
        guard all[mountPoint] != address else { return }
        all[mountPoint] = address
        UserDefaults.standard.set(all, forKey: key)
    }

    /// The known share (its mount point, "/Volumes/Media") that `path` is on,
    /// when that share isn't mounted right now.
    static func missingShare(containing path: String) -> String? {
        let parts = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return nil }
        let mountPoint = "/Volumes/" + parts[2]
        guard known[mountPoint] != nil, !isMounted(mountPoint) else { return nil }
        return mountPoint
    }

    static func isKnown(_ mountPoint: String) -> Bool { known[mountPoint] != nil }

    private static func isMounted(_ mountPoint: String) -> Bool {
        MountInfo.of(mountPoint)?.mountPoint == mountPoint
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
