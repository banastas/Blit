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

    func promptNewFolder() {
        guard current != nil else { return }
        let names = Set(items.map { $0.name.lowercased() })
        var name = "untitled folder"
        var n = 2
        while names.contains(name) { name = "untitled folder \(n)"; n += 1 }
        namePrompt = NamePrompt(kind: .newFolder, name: name)
    }

    func promptRename(_ item: FileItem) {
        namePrompt = NamePrompt(kind: .rename(item), name: item.name)
    }

    func commit(_ prompt: NamePrompt) {
        guard let folder = current else { return }
        Task {
            do {
                switch prompt.kind {
                case .newFolder:
                    selection = [try await operations.makeFolder(named: prompt.name, in: folder)]
                case .rename(let item):
                    selection = [try await operations.rename(item.location, to: prompt.name)]
                }
            } catch {
                operationError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
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
    func drop(_ sources: [BrowseLocation], into folder: BrowseLocation, name: String) {
        let mode: FileOperations.Mode = NSEvent.modifierFlags.contains(.option) ? .copy : .automatic
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
