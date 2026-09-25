// File management from the browser: the actions behind the File and Edit
// menus, the context menu and drag and drop (PRD R2.12).

import AppKit
import Foundation

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

    /// Ends editing; renames if the name changed. Safe to call more than once.
    func commitRename(_ item: FileItem, to newName: String) {
        guard renaming == item.location else { return }
        renaming = nil
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != item.name else { return }
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
        run(sources: contents.sources, into: folder, name: title, mode: move || contents.isCut ? .move : .copy)
    }

    // MARK: Drag and drop

    /// A drop onto this list or one of its folders: Finder's rules, ⌥ copies.
    /// `copy` is the ⌥ state captured at drop time, when the drop is read later.
    func drop(_ sources: [BrowseLocation], into folder: BrowseLocation, name: String, copy: Bool? = nil) {
        let mode: FileOperations.Mode = (copy ?? NSEvent.modifierFlags.contains(.option)) ? .copy : .automatic
        run(sources: sources, into: folder, name: name, mode: mode)
    }

    private func run(sources: [BrowseLocation], into folder: BrowseLocation, name: String, mode: FileOperations.Mode) {
        let hidden = showHidden
        Task {
            if let message = await operations.place(sources, into: folder, destinationName: name.isEmpty ? "Folder" : name,
                                                    mode: mode, includeHidden: hidden) {
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
