// File management from the browser: the actions behind the File and Edit
// menus, the context menu and drag and drop (PRD R2.12).

import AppKit
import Foundation
import UniformTypeIdentifiers

extension BrowserModel {
    var selectedItems: [FileItem] { rows.filter { selection.contains($0.id) } }

    func items(for locations: Set<BrowseLocation>) -> [FileItem] {
        rows.filter { locations.contains($0.id) }
    }

    func selectAll() { selection = Set(rows.map(\.id)) }

    /// "Move to Trash" for local volumes with a Trash, else "Delete…" (immediate).
    func deleteTitle(for items: [FileItem]) -> String {
        operations.canTrash(items.map(\.location)) ? "Move to Trash" : "Delete…"
    }

    // MARK: Names

    /// Creates "untitled folder" (or "untitled folder 2"…) here at once and
    /// puts its name into editing, like Finder.
    func newFolder() {
        guard let folder = current else { return }
        let names = Set(items.map { $0.name.lowercased() })
        var name = "untitled folder"
        var n = 2
        while names.contains(name) { name = "untitled folder \(n)"; n += 1 }
        Task {
            do {
                let created = try await operations.makeFolder(named: name, in: folder)
                selection = [created]
                renaming = created
            } catch {
                operationError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    /// Starts editing an item's name in place (Return, or File › Rename).
    func beginRename(_ item: FileItem) {
        selection = [item.id]
        renaming = item.location
    }

    func cancelRename() { renaming = nil }

    /// Keeps a file's type on rename: if the old name had a real extension
    /// (.mp4, .mkv, .nfo…) and the new name has none (or only dots that aren't
    /// one, like "…MP4-VACCiNE[XC]"), the old extension is added back. A
    /// different real extension typed on purpose is kept.
    nonisolated static func keepingExtension(of oldName: String, in newName: String, isDirectory: Bool) -> String {
        guard !isDirectory else { return newName }
        func knownExtension(_ name: String) -> String? {
            let ext = (name as NSString).pathExtension
            guard !ext.isEmpty, !ext.contains(" "), let type = UTType(filenameExtension: ext), !type.isDynamic else { return nil }
            return ext
        }
        func plainExtension(_ name: String) -> String? {
            // Short letters-and-digits endings macOS doesn't know (.nfo, .srt, .sfv),
            // but not dates or release tags ("16", "MP4-VACCiNE[XC]").
            let ext = (name as NSString).pathExtension
            let plain = !ext.isEmpty && ext.count <= 5 && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
            return plain && ext.contains(where: \.isLetter) ? ext : nil
        }
        guard let old = knownExtension(oldName) ?? plainExtension(oldName) else { return newName }
        // The new name keeps its own ending only if it's a type macOS knows, or
        // the same unknown extension as before: "Show.S3", "Show.E01" and
        // "Movie.720p" are release tags, not a new type.
        if knownExtension(newName) != nil { return newName }
        if let ext = plainExtension(newName), ext.lowercased() == old.lowercased() { return newName }
        return newName + "." + old
    }

    /// Ends editing; renames if the name changed. Safe to call more than once.
    func commitRename(_ item: FileItem, to newName: String) {
        guard renaming == item.location else { return }
        renaming = nil
        var name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        name = Self.keepingExtension(of: item.name, in: name, isDirectory: item.isDirectory)
        // Byte comparison: "café" typed (NFC) over "café" stored (NFD) is a real
        // rename for a Linux NAS, though Swift's == calls them equal.
        guard Array(name.utf8) != Array(item.name.utf8) else { return }
        Task {
            do {
                selection = [try await operations.rename(item.location, to: name)]
            } catch {
                operationError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }

    /// Opens the selected folder, or a local file in its app (double-click, ⌘↓, ⌘O).
    func openSelection() {
        guard selection.count == 1, let item = selectedItems.first else { return }
        if item.isDirectory {
            open(item.location)
        } else if let url = item.location.localURL {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Pasteboard

    func copy(_ items: [FileItem], cut: Bool) {
        operations.writeToPasteboard(items, cut: cut)
    }

    /// Pastes into the current folder. A Cut (or ⌥⌘V) moves; otherwise copies.
    func paste(move: Bool) {
        guard let folder = current, let contents = operations.pasteboardContents() else { return }
        run(sources: contents.sources, into: folder, name: title, mode: move || contents.isCut ? .move : .copy,
            fromPasteboard: true)
    }

    // MARK: Drag and drop

    /// A drop onto this list or one of its folders: Finder's rules, ⌥ copies.
    /// `copy` is the ⌥ state captured at drop time, when the drop is read later.
    func drop(_ sources: [BrowseLocation], into folder: BrowseLocation, name: String, copy: Bool? = nil) {
        let mode: FileOperations.Mode = (copy ?? NSEvent.modifierFlags.contains(.option)) ? .copy : .automatic
        run(sources: sources, into: folder, name: name, mode: mode)
    }

    private func run(sources: [BrowseLocation], into folder: BrowseLocation, name: String, mode: FileOperations.Mode,
                     fromPasteboard: Bool = false) {
        let hidden = showHidden
        Task {
            if let message = await operations.place(sources, into: folder, destinationName: name.isEmpty ? "Folder" : name,
                                                    mode: mode, includeHidden: hidden, fromPasteboard: fromPasteboard) {
                operationError = message
            }
        }
    }

    // MARK: Duplicate and delete

    func duplicate(_ items: [FileItem]) {
        Task {
            if let message = await operations.duplicate(items.map(\.location)) { operationError = message }
        }
    }

    /// Local items with a Trash go there straight away (as in Finder); anything
    /// that would be deleted for good asks first.
    func requestDelete(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        if operations.canTrash(items.map(\.location)) {
            Task {
                if let message = await operations.moveToTrash(items.map(\.location)) { operationError = message }
            }
        } else {
            deleteRequest = items
        }
    }

    func confirmDelete(_ items: [FileItem]) {
        deleteRequest = nil
        Task {
            if let message = await operations.deletePermanently(items.map(\.location)) { operationError = message }
        }
    }
}
