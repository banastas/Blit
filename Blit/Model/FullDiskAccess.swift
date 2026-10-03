// Full Disk Access (PRD R2.20). macOS protects some places (iCloud Drive,
// Desktop, Documents, Downloads, the Trash) until the user allows an app in
// System Settings, and it can't ask with a prompt. Without it, changes there
// fail with "you don't have permission" (a Move to Trash in iCloud Drive did).
// Blit explains once, at first launch, shows where it stands in Settings, and
// points at the setting whenever a file operation is turned away for it.

import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class FullDiskAccess {
    static let shared = FullDiskAccess()
    private(set) var isGranted = FullDiskAccess.check()
    @ObservationIgnored private var observer: NSObjectProtocol?

    /// System Settings › Privacy & Security › Full Disk Access.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    private static let offeredKey = "fullDiskAccessOffered"

    private init() {
        // Checked again whenever Blit comes back to the front (from System Settings, say).
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                          object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { FullDiskAccess.shared.refresh() }
        }
    }

    func refresh() {
        #if DEBUG
        if debugFrozen { return }
        #endif
        let now = Self.check()
        if now != isGranted { isGranted = now }
    }

    func openSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }

    /// Whether to offer it at launch: not granted, not offered before, and
    /// not a test copy.
    var shouldOffer: Bool {
        !isGranted && !UserDefaults.standard.bool(forKey: Self.offeredKey) && !TransferManager.isIsolated
    }

    func markOffered() {
        UserDefaults.standard.set(true, forKey: Self.offeredKey)
    }

    /// Whether a failure reads like one macOS's privacy protection caused.
    static func looksBlocked(_ failure: String) -> Bool {
        failure.localizedCaseInsensitiveContains("permission") || failure.localizedCaseInsensitiveContains("not permitted")
    }

    /// Whether Blit can open a file that only Full Disk Access opens: the
    /// user's privacy database. macOS has no API that says; this is how apps
    /// tell. A missing file can't tell, and counts as granted (no nagging).
    nonisolated static func check() -> Bool {
        let fd = open(NSHomeDirectory() + "/Library/Application Support/com.apple.TCC/TCC.db", O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        return errno != EPERM && errno != EACCES
    }

    #if DEBUG
    /// Test pictures: either state, whatever the test copy has (held until
    /// debugRelease, so the views' own re-checks don't undo it).
    @ObservationIgnored private var debugFrozen = false
    func debugSet(_ granted: Bool) {
        debugFrozen = true
        isGranted = granted
    }
    func debugRelease() {
        debugFrozen = false
        refresh()
    }
    #endif
}
