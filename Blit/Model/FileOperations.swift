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
            problems += await Task.detached { Self.duplicateLocal(inPlace) }.value
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
                problems += await Task.detached { Self.moveLocal(sameVolume, into: folder) }.value
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
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    private func moveOnServer(_ sources: [BrowseLocation], into destination: BrowseLocation) async -> String? {
        guard !sources.isEmpty, let server = servers.server(destination.serverID),
              let folder = destination.remotePath else { return nil }
        var problems: [String] = []
        do {
            let client = try await connections.browseClient(for: server)
            for source in sources {
                guard let path = source.remotePath else { continue }
                let target = folder.appending(path.lastComponent)
                do {
                    try await Self.ensureMissing(target, on: client, in: destination.lastComponent)
                    try await client.rename(path, to: target)
                } catch {
                    problems.append(Self.describe(error))
                }
            }
        } catch {
            problems.append(Self.describe(error))
        }
        onChanged?([destination] + sources.compactMap(\.parent))
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
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
        let problems = await Task.detached { Self.duplicateLocal(urls) }.value
        onChanged?(urls.map { .local($0.deletingLastPathComponent()) })
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    // MARK: Delete

    /// Whether deleting `items` moves them to the Trash. Items on servers and on
    /// network shares have no Trash, so they're deleted immediately (as in Finder).
    func canTrash(_ items: [BrowseLocation]) -> Bool {
        items.allSatisfy { item in
            guard let url = item.localURL else { return false }
            return (try? url.resourceValues(forKeys: [.volumeIsLocalKey]))?.volumeIsLocal == true
        }
    }

    func moveToTrash(_ items: [BrowseLocation]) async -> String? {
        let urls = items.compactMap(\.localURL)
        let problems = await Task.detached { () -> [String] in
            urls.compactMap { url in
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    return nil
                } catch {
                    return "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }.value
        onChanged?(items.compactMap(\.parent))
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    /// Deletes immediately; folders go with everything in them. Callers confirm first.
    func deletePermanently(_ items: [BrowseLocation]) async -> String? {
        var problems: [String] = []
        let urls = items.compactMap(\.localURL)
        problems += await Task.detached { () -> [String] in
            urls.compactMap { url in
                do {
                    try FileManager.default.removeItem(at: url)
                    return nil
                } catch {
                    return "\(url.lastPathComponent): \(error.localizedDescription)"
                }
            }
        }.value
        let remote = Dictionary(grouping: items.filter { $0.serverID != nil }, by: { $0.serverID! })
        for (id, locations) in remote {
            guard let server = servers.server(id) else { continue }
            do {
                let client = try await connections.browseClient(for: server)
                for location in locations {
                    guard let path = location.remotePath else { continue }
                    do {
                        try await client.removeRecursively(path)
                    } catch {
                        problems.append("\(location.lastComponent): \(Self.describe(error))")
                    }
                }
            } catch {
                problems.append(Self.describe(error))
            }
        }
        onChanged?(items.compactMap(\.parent))
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
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

    /// Fails if `path` exists: SFTP servers differ on whether a rename replaces its target.
    private static func ensureMissing(_ path: RemotePath, on client: SFTPClient, in folder: String) async throws {
        if (try? await client.stat(path)) != nil {
            let where_ = folder.isEmpty ? "the home folder" : "“\(folder)”"
            throw FileOperationError.message("“\(path.lastComponent)” already exists in \(where_).")
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    nonisolated private static func volumeID(_ url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    nonisolated private static func moveLocal(_ urls: [URL], into folder: URL) -> [String] {
        let fm = FileManager.default
        return urls.compactMap { url in
            let target = folder.appendingPathComponent(url.lastPathComponent)
            if fm.fileExists(atPath: target.path) {
                return "“\(url.lastPathComponent)” already exists in “\(folder.lastPathComponent)”."
            }
            do {
                try fm.moveItem(at: url, to: target)
                return nil
            } catch {
                return "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
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

    nonisolated private static func duplicateLocal(_ urls: [URL]) -> [String] {
        let fm = FileManager.default
        return urls.compactMap { url in
            var isDirectory: ObjCBool = false
            _ = fm.fileExists(atPath: url.path, isDirectory: &isDirectory)
            let target = duplicateURL(for: url, isDirectory: isDirectory.boolValue) { fm.fileExists(atPath: $0) }
            do {
                // copyItem clones on APFS, so this is instant on the same SSD.
                try fm.copyItem(at: url, to: target)
                return nil
            } catch {
                return "\(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }
}
