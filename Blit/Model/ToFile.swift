// To File (PRD R2.27): every download that landed and hasn't been filed yet,
// in one list, wherever it is on this Mac. An item is added when its download
// finishes; it follows the item through renames and moves on the same drive
// (Blit's own, through the same hook as VerifiedIndex), and leaves the list
// once the item is gone from there: moved to a NAS, or to the Trash. Or when
// the user marks it filed. Nothing here moves anything by itself.

import Foundation

@MainActor
@Observable
final class ToFile {
    static let shared = ToFile()

    struct Entry: Codable, Hashable, Sendable {
        var path: String
        var arrived: Date
    }

    private(set) var entries: [Entry] = []

    private init() {
        if let data = try? Data(contentsOf: Self.url),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) { entries = saved }
    }

    static var url: URL {
        #if DEBUG
        if TransferManager.isIsolated { return FileManager.default.temporaryDirectory.appendingPathComponent("blit-test-tofile.json") }
        #endif
        return URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Blit/tofile.json")
    }

    /// Downloads that landed (each item at the top of what arrived).
    func arrived(_ items: [URL], at time: Date = Date()) {
        var changed = false
        for item in items where item.isFileURL && !entries.contains(where: { $0.path == item.path }) {
            entries.append(Entry(path: item.path, arrived: time))
            changed = true
        }
        if changed { save() }
    }

    /// Renamed or moved on the same drive: the entry follows (a folder's own,
    /// and anything listed inside it).
    func moved(from old: URL, to new: URL) {
        var changed = false
        for index in entries.indices {
            let path = entries[index].path
            if path == old.path {
                entries[index].path = new.path
                changed = true
            } else if path.hasPrefix(old.path + "/") {
                entries[index].path = new.path + path.dropFirst(old.path.count)
                changed = true
            }
        }
        if changed { save() }
    }

    /// Filed (or not to be): out of the list, nothing else happens.
    func remove(_ paths: Set<String>) {
        let before = entries.count
        entries.removeAll { paths.contains($0.path) }
        if entries.count != before { save() }
    }

    /// Entries whose item is gone (moved off this drive, trashed, deleted).
    /// Reads the disk off the main thread.
    func prune() async {
        let paths = entries.map(\.path)
        let gone = await Task.detached { Set(paths.filter { !FileManager.default.fileExists(atPath: $0) }) }.value
        remove(gone)
    }

    private func save() {
        let url = Self.url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }

    #if DEBUG
    func resetForTest() {
        entries = []
        try? FileManager.default.removeItem(at: Self.url)
    }
    #endif

    // MARK: Rows

    /// An entry as a file-list item, with what Blit would do with it: the
    /// first naming preset that changes its name, and where things like it went.
    struct Row: Identifiable, Sendable {
        let entry: Entry
        let item: FileItem
        var id: String { entry.path }
    }

    /// The entries that are still there, as items (newest first). Reads the disk.
    func rows() async -> [Row] {
        let entries = entries
        let found = await Task.detached { () -> [Row] in
            entries.compactMap { entry in
                let url = URL(fileURLWithPath: entry.path)
                let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey, .localizedTypeDescriptionKey]
                guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
                let isFolder = (values.isDirectory ?? false) && !(values.isPackage ?? false)
                let item = FileItem(location: .local(url), name: url.lastPathComponent, isDirectory: isFolder,
                                    modified: values.contentModificationDate ?? entry.arrived, size: isFolder ? -1 : Int64(values.fileSize ?? 0),
                                    kind: values.localizedTypeDescription ?? (isFolder ? "Folder" : "Document"))
                return Row(entry: entry, item: item)
            }
        }.value
        return found.sorted { $0.entry.arrived > $1.entry.arrived }
    }

    /// The first preset that renames `item` without a problem, and its new name.
    static func preset(for item: FileItem, siblings: @escaping (BrowseLocation) -> [String]) -> (preset: RenamePreset, row: RenamePlanRow)? {
        for preset in RenamePresets.all() {
            if let row = RenamePlan.rows([item], steps: preset.steps, siblings: siblings).first, row.changes, row.problem == nil {
                return (preset, row)
            }
        }
        return nil
    }
}
