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

    /// Puts `sources` into the folder `destination`. Returns a message when it can't.
    func place(_ sources: [BrowseLocation], into destination: BrowseLocation, destinationName: String,
               mode: Mode, includeHidden: Bool = false) async -> String? {
        if mode == .move { consumeCut() }
        let sources = sources.uniqued()
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
                                      includeHidden: includeHidden)
        }
    }

    private func placeLocally(_ sources: [BrowseLocation], into folder: URL, destinationName: String, mode: Mode,
                              includeHidden: Bool) async -> String? {
        let here = BrowseLocation.local(folder)
        var local = sources.compactMap(\.localURL)
        let remote = sources.filter { $0.serverID != nil }
        var problems: [String] = []

        // Copying into the folder the items are already in: duplicate them, like Finder.
        let inPlace = local.filter { Self.same(.local($0.deletingLastPathComponent()), here) }
        local.removeAll { url in inPlace.contains(url) }
        if mode == .copy, !inPlace.isEmpty {
            problems += await duplicateTracked(inPlace)
            onChanged?([here])
        }

        // Moves within one volume are renames.
        if mode != .copy {
            let volume = Self.volumeID(folder)
            let sameVolume = local.filter { url in
                guard let volume, let other = Self.volumeID(url) else { return false }
                return other.isEqual(volume)
            }
            local.removeAll { url in sameVolume.contains(url) }
            if !sameVolume.isEmpty {
                problems += await track("MOVE", done: "MOVED", sameVolume.map { .local($0) }, to: folder.lastPathComponent) { item in
                    guard let url = item.localURL else { return }
                    try await Task.detached { try Self.moveLocal(url, into: folder) }.value
                    VerifiedIndex.shared.moved(from: url, to: folder.appendingPathComponent(url.lastPathComponent))
                }
                onChanged?([here] + sameVolume.map { .local($0.deletingLastPathComponent()) })
            }
        }

        // Everything else crosses devices: a verified transfer. For a Cut, the
        // sources are removed only once their copies are verified.
        let crossing = local.map { BrowseLocation.local($0) } + remote
        if !crossing.isEmpty {
            // A drag between devices copies (Finder's rule); a server's items only move within it.
            if let message = transfers.enqueue(crossing, to: here, destinationName: destinationName,
                                               includeHidden: includeHidden, move: mode == .move) {
                problems.append(message)
            }
        }
        return Self.summary(problems)
    }

    private func moveOnServer(_ sources: [BrowseLocation], into destination: BrowseLocation) async -> String? {
        guard !sources.isEmpty, let server = servers.server(destination.serverID),
              let folder = destination.remotePath else { return nil }
        var problems: [String] = []
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
            }
        } catch {
            problems.append(Self.describe(error))
        }
        onChanged?([destination] + sources.compactMap(\.parent))
        return Self.summary(problems)
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
        return created
    }

    func rename(_ item: BrowseLocation, to newName: String) async throws -> BrowseLocation {
        let name = try Self.validated(newName)
        guard let parent = item.parent else { return item }
        let renamed: BrowseLocation
        switch item {
        case .local(let url):
            let target = url.deletingLastPathComponent().appendingPathComponent(name)
            guard target.lastPathComponent != url.lastPathComponent else { return item }
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
        return renamed
    }

    /// Copies local items next to themselves as “name copy”, like Finder's Duplicate.
    func duplicate(_ items: [BrowseLocation]) async -> String? {
        let urls = items.compactMap(\.localURL)
        guard !urls.isEmpty else { return "Duplicate works on local items only." }
        let problems = await duplicateTracked(urls)
        onChanged?(urls.map { .local($0.deletingLastPathComponent()) })
        return Self.summary(problems)
    }

    // MARK: Delete

    /// Whether deleting `items` moves them to the Trash. Items on servers and on
    /// network shares have no Trash, so they're deleted immediately (as in Finder).
    func canTrash(_ items: [BrowseLocation]) -> Bool {
        let local = items.compactMap(\.localURL)
        guard local.count == items.count else { return false }
        // Judge by the volume, via the parent folder: an item that has already
        // vanished (moved in Finder) mustn't turn a trash into a permanent delete.
        let present = local.filter { FileManager.default.fileExists(atPath: $0.path) }
        let probes = present.isEmpty ? local.map { $0.deletingLastPathComponent() } : present
        return probes.allSatisfy { (try? $0.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == true }
    }

    func moveToTrash(_ items: [BrowseLocation]) async -> String? {
        let problems = await track("TRASH", done: "MOVED TO TRASH", items, to: "Trash") { item in
            guard let url = item.localURL else { return }
            try await Task.detached {
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                } catch CocoaError.fileNoSuchFile {
                    // Already gone: nothing to trash.
                }
            }.value
            VerifiedIndex.shared.removed(url)
        }
        onChanged?(items.compactMap(\.parent))
        return Self.summary(problems)
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
        return Self.summary(problems)
    }

    // MARK: Helpers

    /// Whether `inner` is `outer` or somewhere inside it.
    static func location(_ outer: BrowseLocation, contains inner: BrowseLocation) -> Bool {
        switch (outer, inner) {
        case (.local(let a), .local(let b)):
            let a = a.standardizedFileURL.path, b = b.standardizedFileURL.path
            return a == b || b.hasPrefix(a == "/" ? "/" : a + "/")
        case (.remote(let s1, let a), .remote(let s2, let b)):
            guard s1 == s2, !a.isEmpty else { return false }
            return a == b || b.starts(with: a + [UInt8(ascii: "/")])
        default:
            return false
        }
    }

    /// Same folder, ignoring how the URL was spelled.
    static func same(_ a: BrowseLocation, _ b: BrowseLocation) -> Bool {
        if let x = a.localURL, let y = b.localURL { return x.standardizedFileURL.path == y.standardizedFileURL.path }
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

    /// Problems for an alert: repeats dropped, and at most five listed.
    private static func summary(_ problems: [String]) -> String? {
        let unique = problems.uniqued()
        guard !unique.isEmpty else { return nil }
        let shown = unique.prefix(5).joined(separator: "\n")
        return unique.count > 5 ? shown + "\n…and \(unique.count - 5) more." : shown
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    nonisolated private static func volumeID(_ url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    nonisolated private static func moveLocal(_ url: URL, into folder: URL) throws {
        let fm = FileManager.default
        let target = folder.appendingPathComponent(url.lastPathComponent)
        if target.standardizedFileURL.path == url.deletingLastPathComponent().standardizedFileURL.path {
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
        await track("DUPLICATE", done: "DUPLICATED", urls.map { .local($0) },
                    to: urls.first?.deletingLastPathComponent().lastPathComponent ?? "") { item in
            guard let url = item.localURL else { return }
            try await Task.detached { try Self.duplicateLocal(url) }.value
        }
    }

    /// "SFTP", "SMB" or "LOCAL", for the strip's link label.
    private static func link(for item: BrowseLocation?) -> String {
        guard let item else { return "" }
        if item.serverID != nil { return "SFTP" }
        guard let url = item.localURL else { return "" }
        return (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == false ? "SMB" : "LOCAL"
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
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var n = 1
        while true {
            let name = (n == 1 ? "\(base) copy" : "\(base) copy \(n)") + (ext.isEmpty ? "" : ".\(ext)")
            let candidate = folder.appendingPathComponent(name)
            if !exists(candidate.path) { return candidate }
            n += 1
        }
    }

    nonisolated private static func duplicateLocal(_ url: URL) throws {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        _ = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
        let target = duplicateURL(for: url, isDirectory: isDirectory.boolValue) { fm.fileExists(atPath: $0) }
        // copyItem clones on APFS, so this is instant on the same SSD.
        try fm.copyItem(at: url, to: target)
    }
}
