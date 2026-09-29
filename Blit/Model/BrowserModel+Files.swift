// File management from the browser: the actions behind the File and Edit
// menus, the context menu and drag and drop (PRD R2.12).

import AppKit
import BlitRemote
import BlitSFTP
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
                report(FileOperations.describe(error), action: "NEW FOLDER")
            }
        }
    }

    /// Starts editing an item's name in place (Return, or File › Rename).
    func beginRename(_ item: FileItem) {
        selection = [item.id]
        renaming = item.location
    }

    /// One item renames in place; several open Rename N Items (as in Finder).
    func beginRename(_ items: [FileItem]) {
        if items.count == 1 { beginRename(items[0]) } else if items.count > 1 { batchRenameItems = items }
    }

    func commitBatchRename(_ rows: [RenamePlanRow]) {
        let plan = rows.map { (item: $0.item.location, name: $0.newName) }
        Task {
            if let message = await operations.renameMany(plan) { report(message, action: "RENAME") }
            let renamed = plan.compactMap { entry in entry.item.parent.map { FileOperations.child(of: $0, named: entry.name) } }
            selection = Set(renamed)
        }
    }

    // MARK: Copy To / Move To

    /// Folders offered by Copy To ▸ and Move To ▸: set by the window from the
    /// sidebar's favorites (NAS folders first).
    @MainActor static var destinations: () -> [(name: String, detail: String?, location: BrowseLocation)] = { [] }

    /// Verified copy (or move: each source removed once its copy is verified)
    /// into `folder`, as a drop there would.
    func send(_ items: [FileItem], to folder: BrowseLocation, name: String, move: Bool) {
        drop(items.map(\.location), into: folder, name: name, copy: !move)
    }

    /// Copy (F5) or move (F6) the selection into the folder the other pane shows.
    func sendToOtherPane(move: Bool) {
        guard !selection.isEmpty, let other = BrowserModel.oppositePane?(self), let there = other.current,
              there != current else { return }
        send(selectedItems, to: there, name: other.title, move: move)
    }

    /// Whether F5 / F6 have somewhere to go: a selection and another pane
    /// showing a different folder.
    var canSendToOtherPane: Bool {
        guard !selection.isEmpty, let other = BrowserModel.oppositePane?(self), let there = other.current else { return false }
        return there != current
    }

    /// Opens the selected folder in the other pane.
    func openSelectionInOtherPane() {
        guard selection.count == 1, let item = selectedItems.first, item.isDirectory,
              let other = BrowserModel.oppositePane?(self) else { return }
        other.open(item.location)
    }

    /// Copy To / Move To › Other Folder…: pick any local folder.
    func sendToChosenFolder(_ items: [FileItem], move: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = move ? "Move Here" : "Copy Here"
        panel.message = move ? "Each file is removed from here once its copy is verified by SHA-256." : "Copies are verified by SHA-256."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        send(items, to: .local(url), name: url.lastPathComponent, move: move)
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
                report(FileOperations.describe(error), action: "RENAME")
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
                report(message, action: mode == .copy ? "COPY" : "MOVE")
            }
        }
    }

    // MARK: Duplicate and delete

    func duplicate(_ items: [FileItem]) {
        Task {
            if let message = await operations.duplicate(items.map(\.location)) { report(message, action: "DUPLICATE") }
        }
    }

    /// Local items with a Trash go there straight away (as in Finder); anything
    /// that would be deleted for good asks first.
    func requestDelete(_ items: [FileItem]) {
        guard !items.isEmpty else { return }
        if operations.canTrash(items.map(\.location)) {
            Task {
                if let message = await operations.moveToTrash(withResumeData(items)) { report(message, action: "MOVE TO TRASH") }
            }
        } else {
            deleteRequest = items
        }
    }

    func confirmDelete(_ items: [FileItem]) {
        deleteRequest = nil
        Task {
            if let message = await operations.deletePermanently(withResumeData(items)) { report(message, action: "DELETE") }
        }
    }

    /// A `.blitpart` goes with its `.state` sidecar, which is useless alone.
    private func withResumeData(_ items: [FileItem]) -> [BrowseLocation] {
        var locations = items.map(\.location)
        for item in items where item.partial != nil {
            guard let url = item.location.localURL else { continue }
            let state = BrowseLocation.local(URL(fileURLWithPath: url.path + ".state"))
            if !locations.contains(state), FileManager.default.fileExists(atPath: url.path + ".state") { locations.append(state) }
        }
        return locations
    }

    // MARK: Partial downloads

    /// The configured server a partial download came from.
    func server(for partial: PartialDownload) -> ServerConfig? {
        guard let source = partial.source else { return nil }
        return servers.servers.first {
            !$0.isNASLogin && $0.host == source.host && $0.port == source.port && $0.username == source.username
        }
    }

    /// Why a partial download can't be resumed from here, or nil if it can.
    func resumeProblem(_ item: FileItem) -> String? {
        guard let partial = item.partial, let url = item.location.localURL else { return "Not a partial download." }
        guard server(for: partial) != nil else {
            return partial.source == nil
                ? "This part file doesn't record its server (it's from an older version of Blit)."
                : "The server it came from (\(partial.source!.host)) isn't in the sidebar anymore."
        }
        let folder = url.deletingLastPathComponent().standardizedFileURL.path
        if operations.transfers.transferJobs.contains(where: { job in
            let destination = job.destination.standardizedFileURL.path
            return (job.isActive || job.status == .queued) && (folder == destination || folder.hasPrefix(destination + "/"))
        }) {
            return "A transfer into this folder is already queued or running."
        }
        return nil
    }

    /// Queues the file again into the part's folder; the download picks up
    /// where the part file left off (PRD R3.6).
    func resumeDownload(_ item: FileItem) {
        guard resumeProblem(item) == nil, let partial = item.partial, let server = server(for: partial),
              let url = item.location.localURL else { return }
        let remoteName = partial.remotePath.bytes.split(separator: UInt8(ascii: "/")).last.map { RemotePath(bytes: Array($0)) }
        let expected = remoteName.map(TransferPlan.localName)! + ".blitpart"
        if item.name != expected {
            report("This part file was renamed. Rename it back to “\(expected)” to resume it, or it would download again from the start.",
                   action: "RESUME DOWNLOAD")
            return
        }
        let folder = url.deletingLastPathComponent()
        let source = BrowseLocation.remote(server: server.id, path: partial.remotePath.bytes)
        if let message = operations.transfers.enqueue([source], to: .local(folder), destinationName: folder.lastPathComponent) {
            report(message, action: "RESUME DOWNLOAD")
        }
    }
}
