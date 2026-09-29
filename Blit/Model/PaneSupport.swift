// Two-pane support (R2.8): which columns the file lists show, and what each
// pane last showed, remembered across launches.

import BlitLocal
import Foundation
import Observation
import SwiftUI

/// Which optional columns the file lists show, shared by both panes and
/// View › Columns, and saved. Widths stay with each pane: shared widths made
/// the two panes' fitting overwrite each other.
@MainActor
@Observable
final class ColumnSettings {
    static let shared = ColumnSettings()
    private static let key = "hiddenColumns"

    /// Column ids that are hidden.
    private(set) var hidden: Set<String> {
        didSet {
            guard !TransferManager.isIsolated else { return }
            UserDefaults.standard.set(Array(hidden).sorted(), forKey: Self.key)
        }
    }

    private init() {
        if let saved = UserDefaults.standard.stringArray(forKey: Self.key) {
            hidden = Set(saved)
        } else {
            // Two-pane defaults (0.2.22): Status becomes a tag after the name and
            // Kind waits in View › Columns, so both panes fit on one line.
            hidden = ["status", "kind"]
        }
    }

    /// The columns that can be hidden (Name always shows), for View › Columns.
    static let optional: [(id: String, title: String)] = [
        ("modified", "Modified"), ("size", "Size"), ("status", "Status"), ("kind", "Kind"),
    ]

    func isShown(_ id: String) -> Bool { !hidden.contains(id) }

    func toggle(_ id: String) { set(id, shown: !isShown(id)) }

    func set(_ id: String, shown: Bool) {
        if shown { hidden.remove(id) } else { hidden.insert(id) }
    }
}

/// The window's two panes, for the menus and the context menu: which pane is
/// the other one, and swapping them. Kept by ContentView; observable, so
/// F5 / F6 enable as soon as the second pane appears. (A closure over the
/// view's state read stale values when the menus evaluated it.)
@MainActor
@Observable
final class Panes {
    static let shared = Panes()
    var first: BrowserModel?
    var second: BrowserModel?
    var twoPanes = false

    func other(than model: BrowserModel) -> BrowserModel? {
        guard twoPanes, let first, let second else { return nil }
        return model === first ? second : model === second ? first : nil
    }

    func swap() {
        guard twoPanes, let first, let second, let left = first.current, let right = second.current else { return }
        first.open(right)
        second.open(left)
    }
}

/// What each pane showed last, restored at launch when it's still reachable.
/// Test copies neither save nor restore (they'd overwrite the user's panes).
@MainActor
enum PaneMemory {
    private static func key(_ pane: Int) -> String { "paneLocation\(pane)" }

    static func save(_ location: BrowseLocation?, pane: Int) {
        guard !TransferManager.isIsolated, let location, let data = try? JSONEncoder().encode(location) else { return }
        UserDefaults.standard.set(data, forKey: key(pane))
    }

    /// The saved location if it can be opened now. Drives and shares are
    /// checked against the mount table, never the file system, so a sleeping
    /// NAS can't hold up the launch.
    static func restore(pane: Int, servers: ServerStore) -> BrowseLocation? {
        guard !TransferManager.isIsolated, let data = UserDefaults.standard.data(forKey: key(pane)),
              let location = try? JSONDecoder().decode(BrowseLocation.self, from: data) else { return nil }
        switch location {
        case .remote(let id, _):
            return servers.server(id) == nil ? nil : location
        case .local(let url):
            let parts = url.standardizedFileURL.pathComponents
            if parts.count > 2, parts[1] == "Volumes" {
                let mountPoint = "/Volumes/" + parts[2]
                guard MountInfo.mounted(at: mountPoint) != nil else { return nil }
                // A share is opened as is (a missing folder shows its own message);
                // a local drive is quick to check.
                if VolumeKinds.isNetwork(URL(fileURLWithPath: mountPoint)) { return location }
            }
            return FileManager.default.fileExists(atPath: url.path) ? location : nil
        }
    }
}

/// Free space per volume, for the panes' footers. Read off the main thread
/// (a share that has gone to sleep can take seconds to answer) and at most
/// every 30 s per volume.
@MainActor
@Observable
final class FreeSpace {
    static let shared = FreeSpace()
    private(set) var bytes: [String: Int64] = [:]
    @ObservationIgnored private var asked: [String: Date] = [:]

    /// The volume a local path is on: "/Volumes/<name>", or "/" for the startup disk.
    static func volumeRoot(of url: URL) -> String {
        let parts = url.standardizedFileURL.pathComponents
        return parts.count > 2 && parts[1] == "Volumes" ? "/Volumes/" + parts[2] : "/"
    }

    /// The last known free space for `url`'s volume (refreshed in the background).
    func free(at url: URL) -> Int64? {
        let root = Self.volumeRoot(of: url)
        if asked[root].map({ Date().timeIntervalSince($0) > 30 }) ?? true {
            asked[root] = Date()
            Task.detached {
                let values = try? URL(fileURLWithPath: root).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
                // "Important usage" counts purgeable space on local disks, but reads
                // 0 on a share: take whichever is larger.
                let important = values?.volumeAvailableCapacityForImportantUsage ?? 0
                let plain = Int64(values?.volumeAvailableCapacity ?? 0)
                let free: Int64? = max(important, plain) > 0 ? max(important, plain) : nil
                await MainActor.run { if let free { FreeSpace.shared.bytes[root] = free } }
            }
        }
        return bytes[root]
    }
}
