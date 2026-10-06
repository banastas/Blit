// File management on drives, NAS shares and servers (PRD R2.12): new folder,
// rename, delete, duplicate, and moving or copying items with Cut/Copy/Paste
// or drag and drop.
//
// A move within one volume (or one server) is a rename: instant, nothing is
// copied. Anything that crosses devices goes through the verified transfer
// engines, and a cross-device move deletes each source file only after its
// copy is verified by SHA-256.

import AppKit
import BlitRemote
import BlitSFTP
import Foundation
import Observation
import UniformTypeIdentifiers

enum FileOperationError: Error, LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let text): text
        }
    }
}

@MainActor
@Observable
final class FileOperations {
    enum Mode {
        case copy, move
        /// Finder's drag rules: move within a volume or server, copy across.
        case automatic
    }

    @ObservationIgnored let servers: ServerStore
    @ObservationIgnored let connections: ConnectionManager
    @ObservationIgnored let transfers: TransferManager
    /// Called with folders whose contents changed, so browsers showing them reload.
    @ObservationIgnored var onChanged: (([BrowseLocation]) -> Void)?
    /// The pasteboard change count when Blit last put a Cut on it.
    @ObservationIgnored private var cutChangeCount: Int?
    /// The window's undo manager (Edit › Undo, ⌘Z).
    @ObservationIgnored weak var undoManager: UndoManager?
    /// True while an undo runs, so it doesn't register another undo.
    @ObservationIgnored private var undoing = false
    /// True during a batch rename, which registers one undo for the whole batch.
    @ObservationIgnored private var batching = false

    // MARK: Undo

    /// Registers an undo step for Edit › Undo. The step runs asynchronously;
    /// there's no redo (AppKit only records one when the undo completes at once).
    private func registerUndo(_ name: String, _ undo: @escaping @MainActor (FileOperations) async -> String?) {
        guard !undoing, !batching, let undoManager else { return }
        undoManager.registerUndo(withTarget: self) { operations in
            MainActor.assumeIsolated {
                Task { @MainActor in
                    operations.undoing = true
                    let problem = await undo(operations)
                    operations.undoing = false
                    if let problem { operations.onUndoProblem?("Couldn't undo \(name.lowercased()): \(problem)") }
                }
            }
        }
        undoManager.setActionName(name)
    }

    /// Shows a problem from an undo (set by the window).
    @ObservationIgnored var onUndoProblem: ((String) -> Void)?

    /// Moves local items back: each (from, to) pair moves `to` back to `from`.
    nonisolated private static func moveBack(_ pairs: [(from: URL, to: URL)]) -> [String] {
        let fm = FileManager.default
        return pairs.compactMap { pair in
            if fm.fileExists(atPath: pair.from.path) { return "“\(pair.from.lastPathComponent)” is back in its old place already" }
            do {
                try fm.moveItem(at: pair.to, to: pair.from)
                return nil
            } catch {
                return "\(pair.to.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// Moves created items (a new folder, duplicates) to the Trash.
    nonisolated private static func trash(_ urls: [URL]) -> [String] {
        urls.compactMap { url in
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                return nil
            } catch {
                return "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    init(servers: ServerStore, connections: ConnectionManager, transfers: TransferManager) {
        self.servers = servers
        self.connections = connections
        self.transfers = transfers
    }

    // MARK: Pasteboard

    private static let locationsType = NSPasteboard.PasteboardType(UTType.blitLocations.identifier)

    /// Puts `items` on the pasteboard: Blit's own type for everything, plus file
    /// URLs for local items so Finder can paste them too.
    func writeToPasteboard(_ items: [FileItem], cut: Bool) {
        guard !items.isEmpty else { return }
        let payload = TransferPayload(locations: items.map(\.location), folders: items.filter(\.isDirectory).map(\.location))
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let entries = items.enumerated().map { index, item in
            let entry = NSPasteboardItem()
            if let url = item.location.localURL { entry.setString(url.absoluteString, forType: .fileURL) }
            entry.setString(item.name, forType: .string)
            if index == 0, let data = try? JSONEncoder().encode(payload) { entry.setData(data, forType: Self.locationsType) }
            return entry
        }
        pasteboard.writeObjects(entries)
        cutChangeCount = cut ? pasteboard.changeCount : nil
    }

    /// What Paste would bring in: items copied or cut in Blit, or files copied in Finder.
    func pasteboardContents() -> (sources: [BrowseLocation], isCut: Bool)? {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: Self.locationsType),
           let payload = try? JSONDecoder().decode(TransferPayload.self, from: data), !payload.locations.isEmpty {
            return (payload.locations, cutChangeCount == pasteboard.changeCount)
        }
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.isEmpty ? nil : (urls.map { .local($0) }, false)
    }

    var canPaste: Bool {
        NSPasteboard.general.availableType(from: [Self.locationsType, .fileURL]) != nil
    }

    /// A cut has been pasted; the pasteboard no longer means "move".
    private func consumeCut() { cutChangeCount = nil }

    // MARK: Moving and copying

    /// Puts `sources` into the folder `destination`, from the tab `tab` (a
    /// transfer belongs to it). Returns a message when it can't.
    func place(_ sources: [BrowseLocation], into destination: BrowseLocation, destinationName: String,
               mode: Mode, includeHidden: Bool = false, fromPasteboard: Bool = false, tab: UUID? = nil) async -> String? {
        let result = await placeChecked(sources, into: destination, destinationName: destinationName, mode: mode,
                                        includeHidden: includeHidden, tab: tab)
        // A pasted Cut is used up only when it worked, and the pasteboard then
        // no longer points at the items' old places (Paste again would fail).
        if fromPasteboard, mode == .move, result == nil {
            consumeCut()
            NSPasteboard.general.clearContents()
        }
        return result
    }

    private func placeChecked(_ sources: [BrowseLocation], into destination: BrowseLocation, destinationName: String,
                              mode: Mode, includeHidden: Bool, tab: UUID?) async -> String? {
        // An item inside another selected folder goes with that folder.
        let sources = sources.uniqued().filter { item in
            !sources.contains { $0 != item && Self.location($0, contains: item) }
        }
        guard !sources.isEmpty else { return nil }
        if sources.contains(where: { Self.location($0, contains: destination) }) {
            return "Can't put a folder inside itself."
        }
        switch destination {
        case .remote(let serverID, _):
            guard sources.allSatisfy({ $0.serverID == serverID }) else {
                return sources.contains { $0.serverID == nil }
                    ? "Uploading to a server isn't supported yet."
                    : "Blit can't copy between two servers yet."
            }
            guard mode != .copy else {
                return "Blit can't copy files within a server yet. Cut and paste, or drag without ⌥, to move them."
            }
            return await moveOnServer(sources.filter { $0.parent != destination }, into: destination)
        case .local(let folder):
            return await placeLocally(sources, into: folder, destinationName: destinationName, mode: mode,
                                      includeHidden: includeHidden, tab: tab)
        }
    }

    private func placeLocally(_ sources: [BrowseLocation], into folder: URL, destinationName: String, mode: Mode,
                              includeHidden: Bool, tab: UUID?) async -> String? {
        let here = BrowseLocation.local(folder)
        var local = sources.compactMap(\.localURL)
        var remote = sources.filter { $0.serverID != nil }
        var problems: [String] = []

        // Copying into the folder the items are already in: duplicate them, like Finder.
        let inPlace = local.filter { Self.same(.local($0.deletingLastPathComponent()), here) }
        local.removeAll { url in inPlace.contains(url) }
        if mode == .copy, !inPlace.isEmpty {
            problems += await duplicateTracked(inPlace)
            onChanged?([here])
        }

        // Files that would land on an existing file: ask first, as Finder does
        // (Replace / Keep Both / Skip / Stop), instead of failing them later.
        var existsOverride: ExistsRule?
        var replacing = Set<String>()
        var keepingBoth = Set<String>()
        let conflicts = await ConflictPrompt.conflicts(local.map { .local($0) } + remote, in: folder)
        if !conflicts.isEmpty {
            let volume = Self.volumeID(folder)
            let moves = mode == .move || (mode == .automatic && remote.isEmpty && local.allSatisfy { url in
                guard let volume, let other = Self.volumeID(url) else { return false }
                return other.isEqual(volume)
            })
            switch await ConflictPrompt.ask(conflicts, folderName: destinationName, move: moves) {
            case .stop:
                return ""   // cancelled: nothing to report, and a Cut stays on the pasteboard
            case .skip:
                let skipped = Set(conflicts.map(\.source))
                local.removeAll { skipped.contains(.local($0)) }
                remote.removeAll { skipped.contains($0) }
                if local.isEmpty, remote.isEmpty { return Self.summary(problems) }
            case .replace:
                existsOverride = .replace
                replacing = Set(conflicts.map(\.name))
            case .keepBoth:
                existsOverride = .keepBoth
                keepingBoth = Set(conflicts.map(\.name))
            }
        }

        // Moves within one volume are renames.
        if mode != .copy {
            let volume = Self.volumeID(folder)
            let sameVolume = local.filter { url in
                guard let volume, let other = Self.volumeID(url) else { return false }
                // A file only in the cloud (iCloud Drive, Proton Drive…) goes as a
                // verified copy: renaming its placeholder out of the provider's
                // folder can fail, and reading it downloads it.
                return other.isEqual(volume) && !CloudFolders.isDataless(url.path)
            }
            local.removeAll { url in sameVolume.contains(url) }
            if !sameVolume.isEmpty {
                var moved: [(from: URL, to: URL)] = []
                problems += await track("MOVE", done: "MOVED", sameVolume.map { .local($0) }, to: folder.lastPathComponent) { item in
                    guard let url = item.localURL else { return }
                    var target = folder.appendingPathComponent(url.lastPathComponent)
                    let name = url.lastPathComponent
                    if replacing.contains(name) {
                        // Replace: the existing file goes to the Trash (deleted where there's none).
                        let existing = target
                        try await Task.detached {
                            let fm = FileManager.default
                            do { try fm.trashItem(at: existing, resultingItemURL: nil) } catch { try fm.removeItem(at: existing) }
                        }.value
                    }
                    if keepingBoth.contains(name) {
                        target = URL(fileURLWithPath: ExistsRule.keepBothPath(target.path) { FileManager.default.fileExists(atPath: $0) })
                        let destination = target
                        try await Task.detached { try FileManager.default.moveItem(at: url, to: destination) }.value
                    } else {
                        try await Task.detached { try Self.moveLocal(url, into: folder) }.value
                    }
                    VerifiedIndex.shared.moved(from: url, to: target)
                    moved.append((url, target))
                }
                let changed = [here] + sameVolume.map { BrowseLocation.local($0.deletingLastPathComponent()) }
                onChanged?(changed)
                if !moved.isEmpty {
                    let pairs = moved
                    registerUndo("Move") { operations in
                        let problems = await Task.detached { Self.moveBack(pairs) }.value
                        for pair in pairs { VerifiedIndex.shared.moved(from: pair.to, to: pair.from) }
                        operations.onChanged?(changed)
                        return operations.report(problems)
                    }
                }
            }
        }

        // Everything else crosses devices: a verified transfer. For a Cut, the
        // sources are removed only once their copies are verified.
        let crossing = local.map { BrowseLocation.local($0) } + remote
        if !crossing.isEmpty {
            // A drag between devices copies (Finder's rule); a server's items only move within it.
            if let message = transfers.enqueue(crossing, to: here, destinationName: destinationName,
                                               includeHidden: includeHidden, move: mode == .move, existsRule: existsOverride,
                                               tab: tab) {
                problems.append(message)
            }
        }
        return report(problems)
    }

    private func moveOnServer(_ sources: [BrowseLocation], into destination: BrowseLocation) async -> String? {
        guard !sources.isEmpty, let server = servers.server(destination.serverID),
              let folder = destination.remotePath else { return nil }
        var problems: [String] = []
        var moved: [(from: RemotePath, to: RemotePath)] = []
        do {
            let client = try await connections.browseClient(for: server)
            problems = await track("MOVE", done: "MOVED", sources, to: destination.lastComponent) { source in
                guard let path = source.remotePath else { return }
                let target = folder.appending(path.lastComponent)
                if source.parent?.remotePath == target {
                    throw Self.sameNameAsFolder(path.lastComponent.description, into: destination.lastComponent)
                }
                try await Self.ensureMissing(target, on: client, in: destination.lastComponent)
                try await client.rename(path, to: target)
                moved.append((path, target))
            }
        } catch {
            problems.append(Self.describe(error))
        }
        let changed = [destination] + sources.compactMap(\.parent)
        onChanged?(changed)
        if !moved.isEmpty {
            let pairs = moved
            registerUndo("Move") { operations in
                var problems: [String] = []
                do {
                    let client = try await operations.connections.browseClient(for: server)
                    for pair in pairs {
                        do {
                            try await Self.ensureMissing(pair.from, on: client, in: "its old folder")
                            try await client.rename(pair.to, to: pair.from)
                        } catch {
                            problems.append(Self.describe(error))
                        }
                    }
                } catch {
                    problems.append(Self.describe(error))
                }
                operations.onChanged?(changed)
                return operations.report(problems)
            }
        }
        return report(problems)
    }

    // MARK: New folder, rename, duplicate

    func makeFolder(named name: String, in folder: BrowseLocation) async throws -> BrowseLocation {
        let name = try Self.validated(name)
        let created: BrowseLocation
        switch folder {
        case .local(let url):
            let target = url.appendingPathComponent(name, isDirectory: true)
            try await Task.detached { try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false) }.value
            created = .local(target)
        case .remote(let id, let bytes):
            guard let server = servers.server(id) else { throw FileOperationError.message("That server no longer exists.") }
            let client = try await connections.browseClient(for: server)
            let target = RemotePath(bytes: bytes).appending(RemotePath(name))
            try await Self.ensureMissing(target, on: client, in: folder.lastComponent)
            try await client.makeDirectory(target)
            created = .remote(id, target)
        }
        onChanged?([folder])
        registerUndo("New Folder") { operations in
            switch created {
            case .local(let url):
                let problems = await Task.detached { Self.trash([url]) }.value
                operations.onChanged?([folder])
                return operations.report(problems)
            case .remote(let id, let bytes):
                guard let server = operations.servers.server(id) else { return "That server no longer exists." }
                do {
                    // Only if it's still empty.
                    let client = try await operations.connections.browseClient(for: server)
                    if try await !client.list(RemotePath(bytes: bytes)).isEmpty { return "it isn't empty any more" }
                    try await client.removeDirectory(RemotePath(bytes: bytes))
                    operations.onChanged?([folder])
                    return nil
                } catch {
                    return Self.describe(error)
                }
            }
        }
        return created
    }

    /// New Folder with Selection: a folder named `name` in `folder` with
    /// `items` (all in `folder`) moved into it, as one step to undo, which
    /// moves them back and removes the folder if nothing else is in it.
    /// Returns the folder, and any problem moving the items.
    func makeFolder(named name: String, in folder: BrowseLocation,
                    moving items: [BrowseLocation]) async throws -> (folder: BrowseLocation, problem: String?) {
        // The folder and the move register no undo steps of their own.
        batching = true
        let created: BrowseLocation
        do {
            created = try await makeFolder(named: name, in: folder)
        } catch {
            batching = false
            throw error
        }
        let problem = await place(items, into: created, destinationName: created.lastComponent, mode: .move)
        batching = false
        registerUndo("New Folder with Selection") { operations in
            let inside = items.map { Self.child(of: created, named: $0.lastComponent) }
            if let problem = await operations.place(inside, into: folder, destinationName: folder.lastComponent, mode: .move) {
                return problem.isEmpty ? "the move back was stopped" : problem
            }
            return await operations.removeIfEmpty(created, in: folder)
        }
        return (created, problem?.isEmpty == true ? nil : problem)
    }

    /// Removes a folder New Folder made, if nothing is in it (Finder's
    /// .DS_Store doesn't count).
    private func removeIfEmpty(_ created: BrowseLocation, in folder: BrowseLocation) async -> String? {
        switch created {
        case .local(let url):
            let contents = await Task.detached { (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [] }.value
            guard contents.allSatisfy({ $0 == ".DS_Store" }) else { return "“\(url.lastPathComponent)” isn't empty any more" }
            let problems = await Task.detached { Self.trash([url]) }.value
            onChanged?([folder])
            return report(problems)
        case .remote(let id, let bytes):
            guard let server = servers.server(id) else { return "That server no longer exists." }
            do {
                let client = try await connections.browseClient(for: server)
                if try await !client.list(RemotePath(bytes: bytes)).isEmpty { return "“\(created.lastComponent)” isn't empty any more" }
                try await client.removeDirectory(RemotePath(bytes: bytes))
                onChanged?([folder])
                return nil
            } catch {
                return Self.describe(error)
            }
        }
    }

    func rename(_ item: BrowseLocation, to newName: String) async throws -> BrowseLocation {
        let name = try Self.validated(newName)
        guard let parent = item.parent else { return item }
        let renamed: BrowseLocation
        switch item {
        case .local(let url):
            let target = url.deletingLastPathComponent().appendingPathComponent(name)
            guard Array(target.lastPathComponent.utf8) != Array(url.lastPathComponent.utf8) else { return item }
            try await Task.detached {
                let fm = FileManager.default
                // A change of case alone is fine on a case-insensitive volume.
                let caseOnly = target.lastPathComponent.lowercased() == url.lastPathComponent.lowercased()
                if !caseOnly, fm.fileExists(atPath: target.path) {
                    throw FileOperationError.message("“\(name)” already exists in “\(url.deletingLastPathComponent().lastPathComponent)”.")
                }
                try fm.moveItem(at: url, to: target)
            }.value
            VerifiedIndex.shared.moved(from: url, to: target)
            renamed = .local(target)
        case .remote(let id, _):
            guard let server = servers.server(id), let path = item.remotePath, let folder = parent.remotePath else {
                throw FileOperationError.message("That server no longer exists.")
            }
            let target = folder.appending(RemotePath(name))
            guard target != path else { return item }
            let client = try await connections.browseClient(for: server)
            try await Self.ensureMissing(target, on: client, in: parent.lastComponent)
            try await client.rename(path, to: target)
            renamed = .remote(id, target)
        }
        onChanged?([parent])
        let oldName = item.lastComponent
        registerUndo("Rename") { operations in
            do {
                _ = try await operations.rename(renamed, to: oldName)
                return nil
            } catch {
                return Self.describe(error)
            }
        }
        return renamed
    }

    /// Renames several items (File › Rename N Items…). Names that swap within
    /// the batch go through a temporary name, so the order doesn't matter. One
    /// undo step puts them all back. Returns problems not already in the strip.
    func renameMany(_ plan: [(item: BrowseLocation, name: String)]) async -> String? {
        struct Step { var from: BrowseLocation; var name: String }
        func key(_ location: BrowseLocation, _ name: String) -> String {
            "\(location.parent.map { "\($0)" } ?? "")|\(name.lowercased())"
        }
        // Order the renames so none lands on a name another pending item still has.
        var pending = plan.filter { Array($0.name.utf8) != Array($0.item.lastComponent.utf8) }.map { Step(from: $0.item, name: $0.name) }
        var occupied = Set(pending.map { key($0.from, $0.from.lastComponent) })
        var steps: [Step] = []
        while !pending.isEmpty {
            if let i = pending.firstIndex(where: { step in
                let target = key(step.from, step.name)
                return !occupied.contains(target) || target == key(step.from, step.from.lastComponent)
            }) {
                let step = pending.remove(at: i)
                occupied.remove(key(step.from, step.from.lastComponent))
                occupied.insert(key(step.from, step.name))
                steps.append(step)
            } else {
                // A cycle (a ↔ b): move one aside first.
                let step = pending[0]
                let temporary = step.from.lastComponent + ".blit-rename"
                guard let parent = step.from.parent else { break }
                steps.append(Step(from: step.from, name: temporary))
                occupied.remove(key(step.from, step.from.lastComponent))
                occupied.insert(key(step.from, temporary))
                pending[0].from = Self.child(of: parent, named: temporary)
            }
        }
        guard !steps.isEmpty else { return nil }
        var origin: [BrowseLocation: BrowseLocation] = [:]   // current location → where it started
        var index = 0
        batching = true
        let folder = steps[0].from.parent?.lastComponent ?? ""
        let problems = await track("RENAME", done: "RENAMED", steps.map(\.from), to: folder) { _ in
            let step = steps[index]
            index += 1
            let renamed = try await self.rename(step.from, to: step.name)
            origin[renamed] = origin.removeValue(forKey: step.from) ?? step.from
        }
        batching = false
        let back = origin.filter { $0.key != $0.value }.map { (item: $0.key, name: $0.value.lastComponent) }
        if !back.isEmpty {
            registerUndo(back.count == 1 ? "Rename" : "Rename \(back.count) Items") { operations in
                await operations.renameMany(back)
            }
        }
        return report(problems)
    }

    /// `name` inside `folder`.
    static func child(of folder: BrowseLocation, named name: String) -> BrowseLocation {
        switch folder {
        case .local(let url): .local(url.appendingPathComponent(name))
        case .remote(let id, let bytes): .remote(id, RemotePath(bytes: bytes).appending(RemotePath(name)))
        }
    }

    /// Copies local items next to themselves as “name copy”, like Finder's Duplicate.
    func duplicate(_ items: [BrowseLocation]) async -> String? {
        let urls = items.compactMap(\.localURL)
        guard !urls.isEmpty else { return "Duplicate works on local items only." }
        let problems = await duplicateTracked(urls)
        onChanged?(urls.map { .local($0.deletingLastPathComponent()) })
        return report(problems)
    }

    // MARK: Delete

    /// Whether deleting `items` moves them to the Trash. Items on servers and on
    /// network shares have no Trash, so they're deleted immediately (as in Finder).
    func canTrash(_ items: [BrowseLocation]) -> Bool {
        let local = items.compactMap(\.localURL)
        guard local.count == items.count else { return false }
        // Judged by volume kind from the sidebar's scan, not the file system: this
        // runs for menu titles, and a query on a dead share would freeze the app.
        // (An item that already vanished stays trashable: its volume still is.)
        return local.allSatisfy { !VolumeKinds.isNetwork($0) }
    }

    func moveToTrash(_ items: [BrowseLocation]) async -> String? {
        var trashed: [(from: URL, to: URL)] = []
        let problems = await track("TRASH", done: "MOVED TO TRASH", items, to: "Trash") { item in
            guard let url = item.localURL else { return }
            let inTrash = try await Task.detached { () -> URL? in
                do {
                    var result: NSURL?
                    try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                    return result as URL?
                } catch CocoaError.fileNoSuchFile {
                    return nil   // already gone: nothing to trash
                }
            }.value
            VerifiedIndex.shared.removed(url)
            if let inTrash { trashed.append((url, inTrash)) }
        }
        let changed = items.compactMap(\.parent)
        onChanged?(changed)
        if !trashed.isEmpty {
            // Undo puts them back, as Finder does.
            let pairs = trashed
            registerUndo("Move to Trash") { operations in
                let problems = await Task.detached { Self.moveBack(pairs) }.value
                operations.onChanged?(changed)
                return operations.report(problems)
            }
        }
        return report(problems)
    }

    /// Deletes immediately; folders go with everything in them. Callers confirm first.
    func deletePermanently(_ items: [BrowseLocation]) async -> String? {
        // An item inside another selected folder goes with that folder.
        let items = items.uniqued().filter { item in
            !items.contains { $0 != item && Self.location($0, contains: item) }
        }
        var problems: [String] = []
        let local = items.filter { $0.localURL != nil }
        if !local.isEmpty {
            problems += await track("DELETE", done: "DELETED", local, to: Self.volumeName(of: local[0])) { item in
                guard let url = item.localURL else { return }
                try await Task.detached {
                    do {
                        try FileManager.default.removeItem(at: url)
                    } catch CocoaError.fileNoSuchFile {
                        // Already gone: that's what was asked for.
                    }
                }.value
                VerifiedIndex.shared.removed(url)
            }
        }
        let remote = Dictionary(grouping: items.filter { $0.serverID != nil }, by: { $0.serverID! })
        for (id, locations) in remote {
            guard let server = servers.server(id) else {
                problems.append("That server no longer exists, so nothing was deleted from it.")
                continue
            }
            do {
                let client = try await connections.browseClient(for: server)
                problems += await track("DELETE", done: "DELETED", locations, to: server.displayName) { location, job in
                    guard let path = location.remotePath else { return }
                    try await client.removeRecursively(path) { removed in
                        Task { @MainActor in job.note("DELETED \(removed.description.uppercased())") }
                    }
                }
            } catch {
                problems.append(Self.describe(error))
            }
        }
        onChanged?(items.compactMap(\.parent))
        return report(problems)
    }

    // MARK: Helpers

    /// Whether `inner` is `outer` or somewhere inside it.
    static func location(_ outer: BrowseLocation, contains inner: BrowseLocation) -> Bool {
        switch (outer, inner) {
        case (.local(let a), .local(let b)):
            // Resolve symlinks: a link into the folder is still inside it.
            let a = a.resolvingSymlinksInPath().lexicalPath
            let b = b.resolvingSymlinksInPath().lexicalPath
            return a == b || b.hasPrefix(a == "/" ? "/" : a + "/")
        case (.remote(let s1, let a), .remote(let s2, let b)):
            guard s1 == s2, !a.isEmpty else { return false }
            return a == b || b.starts(with: a + [UInt8(ascii: "/")])
        default:
            return false
        }
    }

    /// `location(_:contains:)` by the paths alone, never asking the disk (so
    /// no symlinks are resolved). For checks that run while the window draws:
    /// resolving a path on a share asks the NAS about every folder in it, and
    /// a share that's asleep or busy blocked the main thread (the tab bar,
    /// once a second while a transfer ran, froze the window).
    static func location(_ outer: BrowseLocation, textuallyContains inner: BrowseLocation) -> Bool {
        switch (outer, inner) {
        case (.local(let a), .local(let b)):
            let a = a.lexicalPath, b = b.lexicalPath
            return a == b || b.hasPrefix(a == "/" ? "/" : a + "/")
        default:
            return location(outer, contains: inner)   // remote paths never touch the disk
        }
    }

    /// Same folder, ignoring how the URL was spelled.
    static func same(_ a: BrowseLocation, _ b: BrowseLocation) -> Bool {
        if let x = a.localURL, let y = b.localURL { return x.lexicalPath == y.lexicalPath }
        return a == b
    }

    private static func validated(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw FileOperationError.message("Enter a name.") }
        guard !name.contains("/"), name != ".", name != ".." else {
            throw FileOperationError.message("Names can't contain “/” or be “.” or “..”.")
        }
        return name
    }

    /// Moving an item up out of a folder with the same name: the folder itself
    /// is the "existing item", which the generic message makes confusing.
    nonisolated private static func sameNameAsFolder(_ name: String, into destination: String) -> FileOperationError {
        .message("“\(name)” has the same name as the folder it's in, so it can't sit next to that folder in “\(destination)”. Rename it first (for a video, add its extension, such as .mp4), then move it.")
    }

    /// Fails unless `path` definitely doesn't exist: SFTP servers differ on
    /// whether a rename replaces its target (SFTPGo does), so any stat answer
    /// other than "no such file" (including permission denied or a timeout)
    /// stops the operation. SFTP v3 can't close the remaining race.
    private static func ensureMissing(_ path: RemotePath, on client: SFTPClient, in folder: String) async throws {
        do {
            _ = try await client.stat(path)
        } catch SFTPError.status(let code, _) where code == SFTPStatusCode.noSuchFile.rawValue {
            return
        } catch {
            throw FileOperationError.message("Couldn't check whether “\(path.lastComponent)” already exists: \(describe(error))")
        }
        let where_ = folder.isEmpty ? "the home folder" : "“\(folder)”"
        throw FileOperationError.message("“\(path.lastComponent)” already exists in \(where_).")
    }

    /// Problems a tracked operation already shows in the strip; they aren't
    /// returned to the caller a second time.
    @ObservationIgnored private var shownInStrip = Set<String>()

    /// The problems still to report (those not already in the strip), summarised.
    private func report(_ problems: [String]) -> String? {
        Self.summary(problems.filter { shownInStrip.remove($0) == nil })
    }

    /// Problems for a notice: repeats dropped, and at most five listed.
    private static func summary(_ problems: [String]) -> String? {
        let unique = problems.uniqued()
        guard !unique.isEmpty else { return nil }
        let shown = unique.prefix(5).joined(separator: "\n")
        return unique.count > 5 ? shown + "\n…and \(unique.count - 5) more." : shown
    }

    /// Readable text for an error: Cocoa and POSIX errors by their localized
    /// description ("The file “a.txt” couldn't be opened…"), Blit's own by theirs.
    static func describe(_ error: Error) -> String {
        if let text = (error as? LocalizedError)?.errorDescription { return text }
        let ns = error as NSError
        if [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain].contains(ns.domain) { return ns.localizedDescription }
        return "\(error)"
    }

    nonisolated private static func volumeID(_ url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    nonisolated private static func moveLocal(_ url: URL, into folder: URL) throws {
        let fm = FileManager.default
        let target = folder.appendingPathComponent(url.lastPathComponent)
        if target.lexicalPath == url.deletingLastPathComponent().lexicalPath {
            throw sameNameAsFolder(url.lastPathComponent, into: folder.lastPathComponent)
        }
        if fm.fileExists(atPath: target.path) {
            throw FileOperationError.message("already exists in “\(folder.lastPathComponent)”")
        }
        try fm.moveItem(at: url, to: target)
    }

    // MARK: Progress in the strip

    /// Runs `work` on each item, showing progress in the transfer strip
    /// (condensed HUD) when it takes more than a moment. Returns problems.
    private func track(_ verb: String, done: String, _ items: [BrowseLocation], to destination: String,
                       _ work: (BrowseLocation, TransferJob) async throws -> Void) async -> [String] {
        let job = transfers.beginOperation(verb, done: done, items: items.map(\.lastComponent),
                                           destination: destination, link: Self.link(for: items.first))
        var problems: [String] = []
        for item in items {
            job.note("\(verb) \(item.lastComponent.uppercased())")
            do {
                try await work(item, job)
            } catch {
                let problem = "\(item.lastComponent): \(Self.describe(error))"
                problems.append(problem)
                job.failures.append(problem)
                job.note("✕ \(problem.uppercased())", failure: true)
                shownInStrip.insert(problem)
            }
            job.filesFinished += 1
        }
        if problems.isEmpty { job.note("✓ \(items.count) \(done)") }
        transfers.finishOperation(job)
        return problems
    }

    private func track(_ verb: String, done: String, _ items: [BrowseLocation], to destination: String,
                       _ work: (BrowseLocation) async throws -> Void) async -> [String] {
        await track(verb, done: done, items, to: destination) { item, _ in try await work(item) }
    }

    private func duplicateTracked(_ urls: [URL]) async -> [String] {
        var copies: [URL] = []
        let problems = await track("DUPLICATE", done: "DUPLICATED", urls.map { .local($0) },
                                   to: urls.first?.deletingLastPathComponent().lastPathComponent ?? "") { item in
            guard let url = item.localURL else { return }
            copies.append(try await Task.detached { try Self.duplicateLocal(url) }.value)
        }
        if !copies.isEmpty {
            let made = copies
            let changed = made.map { BrowseLocation.local($0.deletingLastPathComponent()) }
            registerUndo("Duplicate") { operations in
                let problems = await Task.detached { Self.trash(made) }.value
                operations.onChanged?(changed)
                return operations.report(problems)
            }
        }
        return problems
    }

    /// "SFTP", "SMB" or "LOCAL", for the strip's link label.
    private static func link(for item: BrowseLocation?) -> String {
        guard let item else { return "" }
        if item.serverID != nil { return "SFTP" }
        guard let url = item.localURL else { return "" }
        return VolumeKinds.isNetwork(url) ? "SMB" : "LOCAL"
    }

    private static func volumeName(of item: BrowseLocation) -> String {
        guard let url = item.localURL else { return "" }
        return (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? url.lastPathComponent
    }

    /// Finder's naming: “Movie copy.mkv”, then “Movie copy 2.mkv”; folders keep
    /// dots in their names (“2026.09.16 Pack copy”).
    nonisolated static func duplicateURL(for url: URL, isDirectory: Bool, exists: (String) -> Bool) -> URL {
        let folder = url.deletingLastPathComponent()
        let ext = isDirectory || url.pathExtension.contains(" ") ? "" : url.pathExtension
        var base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        // Duplicating "Movie copy" gives "Movie copy 2", not "Movie copy copy".
        if let range = base.range(of: #" copy( \d+)?$"#, options: .regularExpression) { base.removeSubrange(range) }
        var n = 1
        while true {
            let name = (n == 1 ? "\(base) copy" : "\(base) copy \(n)") + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = folder.appendingPathComponent(name)
            if !exists(candidate.path) { return candidate }
            n += 1
        }
    }

    @discardableResult
    nonisolated private static func duplicateLocal(_ url: URL) throws -> URL {
        let fm = FileManager.default
        // Packages (.fcpbundle, .app, .photoslibrary) are named like files:
        // "Wedding copy.fcpbundle", keeping their type.
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let isFolder = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
        let target = duplicateURL(for: url, isDirectory: isFolder) { fm.fileExists(atPath: $0) }
        // copyItem clones on APFS, so this is instant on the same SSD.
        try fm.copyItem(at: url, to: target)
        return target
    }
}
