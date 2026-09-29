// Two-pane support (R2.8): which columns the file lists show, and what each
// pane last showed, remembered across launches.

import BlitLocal
import Foundation
import Observation
import SwiftUI

/// The file lists' columns (shown, hidden, widths, order), shared by both
/// panes and View › Columns, and saved. (They lived in scene storage, which
/// the View menu couldn't reach.)
@MainActor
@Observable
final class ColumnSettings {
    static let shared = ColumnSettings()
    private static let key = "fileColumns"

    var columns: TableColumnCustomization<FileItem> {
        didSet {
            guard !TransferManager.isIsolated, let data = try? JSONEncoder().encode(columns) else { return }
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    private init() {
        columns = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(TableColumnCustomization<FileItem>.self, from: $0) } ?? TableColumnCustomization()
    }

    /// The columns that can be hidden (Name always shows), for View › Columns.
    static let optional: [(id: String, title: String)] = [
        ("modified", "Date Modified"), ("size", "Size"), ("status", "Status"), ("kind", "Kind"),
    ]

    func isShown(_ id: String) -> Bool { columns[visibility: id] != .hidden }

    func toggle(_ id: String) {
        columns[visibility: id] = isShown(id) ? .hidden : .visible
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
