// The file list for one folder, local or on a server: loading off the main
// thread, sorting (newest first by default, PRD R2.4), back/forward history,
// and the prompts a server connection can need (trust, password).

import BlitRemote
import BlitSFTP
import Foundation
import Observation
import UniformTypeIdentifiers

struct FileItem: Identifiable, Hashable, Sendable {
    var location: BrowseLocation
    var name: String
    var isDirectory: Bool
    var modified: Date
    /// -1 for folders, so they sort below files by size.
    var size: Int64
    var kind: String
    /// Nesting under the current folder when folders are expanded in place.
    var depth = 0
    /// For a resumable `.blitpart`: progress and source, from its sidecar.
    var partial: PartialDownload?
    var id: BrowseLocation { location }
}

/// A server presented a host key Blit hasn't seen (PRD R1.3).
struct TrustRequest: Identifiable {
    let id = UUID()
    let server: ServerConfig
    let presented: HostKeyIdentity
    let known: [HostKeyIdentity]
}

@MainActor
@Observable
final class BrowserModel {
    private(set) var current: BrowseLocation?
    private(set) var items: [FileItem] = []
    private(set) var error: String?
    private(set) var isLoading = false
    /// Newest first unless this folder was sorted otherwise before (SortMemory).
    var sortOrder = SortMemory.standard {
        didSet {
            guard !restoringSort, let current, sortOrder != oldValue else { return }
            SortMemory.set(sortOrder, for: current)
        }
    }
    @ObservationIgnored private var restoringSort = false
    var sortColumn: SortColumn? { SortColumn(sortOrder.first) }

    /// View › Sort By: a column in its usual direction (as in Finder).
    func sort(by column: SortColumn) { sortOrder = [column.comparator()] }
    var trustRequest: TrustRequest?
    var passwordRequest: ServerConfig?
    /// Show names starting with "." (View › Show Hidden Files, ⇧⌘.).
    private(set) var showHidden = false
    var selection = Set<BrowseLocation>()
    /// Folders expanded in place (disclosure triangles), and their contents.
    private(set) var expanded = Set<BrowseLocation>()
    private(set) var children: [BrowseLocation: [FileItem]] = [:]
    private(set) var loadingChildren = Set<BrowseLocation>()
    /// The item whose name is being edited in place, if any.
    var renaming: BrowseLocation?
    /// Items in the Rename N Items sheet.
    var batchRenameItems: [FileItem]?
    /// The item shown in Get Info (⌘I).
    var infoItem: FileItem?
    /// Go to Folder (⇧⌘G) is asking for a path.
    var showGoToFolder = false
    /// Items waiting for the user to confirm a permanent delete.
    var deleteRequest: [FileItem]?
    /// Shows a problem in the transfer strip, where it stays until dismissed
    /// (no alert: there's nothing to decide).
    func report(_ message: String, action: String) {
        operations.transfers.notice(message, action: action, place: current?.lastComponent ?? "")
    }
    /// The file shown in Quick Look, if the panel is open.
    var previewURL: URL?
    /// A server file being downloaded to preview (Space again cancels showing it).
    var previewLoading: BrowseLocation?
    /// Server files already downloaded for Quick Look this session, oldest first.
    @ObservationIgnored var previewDownloads: [(location: BrowseLocation, url: URL)] = []

    func toggleHidden() {
        showHidden.toggle()
        reload()
    }

    let servers: ServerStore
    let connections: ConnectionManager
    let operations: FileOperations
    /// Recently visited folders, newest first (for ⌘K).
    private(set) var recents: [BrowseLocation] = []
    private static let recentsKey = "recentLocations"
    private var backStack: [BrowseLocation] = []
    private var forwardStack: [BrowseLocation] = []

    init(servers: ServerStore, connections: ConnectionManager, operations: FileOperations) {
        self.servers = servers
        self.connections = connections
        self.operations = operations
        if let data = UserDefaults.standard.data(forKey: Self.recentsKey),
           let saved = try? JSONDecoder().decode([BrowseLocation].self, from: data) {
            recents = saved
        }
    }

    private func remember(_ location: BrowseLocation) {
        recents.removeAll { $0 == location }
        recents.insert(location, at: 0)
        if recents.count > 20 { recents.removeLast(recents.count - 20) }
        if let data = try? JSONEncoder().encode(recents) { UserDefaults.standard.set(data, forKey: Self.recentsKey) }
    }

    var sortedItems: [FileItem] { items.sorted(using: sortOrder) }

    /// The rows to show: this folder's items, with the contents of expanded
    /// folders nested under them, each level sorted.
    var rows: [FileItem] {
        var result: [FileItem] = []
        func add(_ list: [FileItem], depth: Int) {
            for var item in list.sorted(using: sortOrder) {
                item.depth = depth
                result.append(item)
                if item.isDirectory, expanded.contains(item.location), let nested = children[item.location] {
                    add(nested, depth: depth + 1)
                }
            }
        }
        add(items, depth: 0)
        return result
    }

    /// Whether this browser shows `folder`, as its location or an expanded folder.
    func shows(_ folder: BrowseLocation) -> Bool {
        guard let current else { return false }
        return FileOperations.same(folder, current) || expanded.contains { FileOperations.same(folder, $0) }
    }

    func toggleExpanded(_ item: FileItem) {
        guard item.isDirectory else { return }
        setExpanded(item.location, !expanded.contains(item.location))
    }

    func setExpanded(_ folder: BrowseLocation, _ open: Bool) {
        guard open != expanded.contains(folder) else { return }
        guard open else {
            expanded.remove(folder)
            selection.formIntersection(rows.map(\.location))
            return
        }
        expanded.insert(folder)
        loadingChildren.insert(folder)
        Task {
            defer { loadingChildren.remove(folder) }
            do {
                children[folder] = try await list(folder)
            } catch {
                expanded.remove(folder)
                report(FileOperations.describe(error), action: "OPEN FOLDER")
            }
        }
    }

    /// Refreshes the contents of expanded folders (after a reload).
    private func reloadExpanded() async {
        let folders = expanded
        let results = await withTaskGroup(of: (BrowseLocation, [FileItem]?).self) { group in
            for folder in folders {
                group.addTask { (folder, try? await self.list(folder)) }
            }
            var results: [(BrowseLocation, [FileItem]?)] = []
            for await result in group { results.append(result) }
            return results
        }
        for (folder, listed) in results {
            if let listed { children[folder] = listed } else { expanded.remove(folder); children[folder] = nil }
        }
    }
    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }
    var canGoUp: Bool { current?.parent != nil }

    var title: String {
        guard let current else { return "Blit" }
        if case .remote = current, current.lastComponent.isEmpty {
            return servers.server(current.serverID)?.displayName ?? "Server"
        }
        return current.lastComponent
    }

    var subtitle: String {
        switch current {
        case .local(let url): return (url.path as NSString).abbreviatingWithTildeInPath
        case .remote(let id, let bytes):
            let name = servers.server(id)?.displayName ?? "server"
            return "\(name):" + (bytes.isEmpty ? "~" : RemotePath(bytes: bytes).description)
        case nil: return ""
        }
    }

    func open(_ location: BrowseLocation) {
        guard location != current else { return }
        if let current { backStack.append(current) }
        forwardStack.removeAll()
        selection = []
        show(location)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        if let current { forwardStack.append(current) }
        selection = []
        show(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        if let current { backStack.append(current) }
        selection = []
        show(next)
    }

    func goUp() {
        if let parent = current?.parent { open(parent) }
    }

    func reload() {
        if let current { show(current) }
    }

    private func show(_ location: BrowseLocation) {
        if location != current {
            // A new folder: start collapsed, showing the last listing (if any)
            // at once while a fresh one loads.
            expanded = []
            children = [:]
            items = connections.listings[location] ?? []
            restoringSort = true
            sortOrder = SortMemory.order(for: location)
            restoringSort = false
        }
        current = location
        isLoading = true
        error = nil
        Task {
            do {
                let listed = try await list(location)
                guard location == current else { return }
                items = listed
                if connections.listings.count > 500 { connections.listings.removeAll() }
                connections.listings[location] = listed
                if !expanded.isEmpty { await reloadExpanded() }
                guard location == current else { return }
                selection.formIntersection(rows.map(\.location))
                if let renaming, !rows.contains(where: { $0.location == renaming }) { self.renaming = nil }
                remember(location)
            } catch {
                guard location == current else { return }
                // An unavailable NAS share Blit knows: reconnect it and try again (PRD R1.5).
                if let url = location.localURL, let share = ShareMounter.missingShare(containing: url.path) {
                    if let problem = await ShareMounter.reconnect(share) {
                        items = []
                        self.error = problem
                    } else if location == current {
                        isLoading = false
                        show(location)   // mounted again: list it
                        return
                    }
                } else {
                    items = []
                    handle(error, for: location)
                }
            }
            isLoading = false
        }
    }

    private func list(_ location: BrowseLocation) async throws -> [FileItem] {
        switch location {
        case .local(let url):
            let hidden = showHidden
            return try await Task.detached { try Self.listLocal(url, showHidden: hidden) }.value
        case .remote(let id, let bytes):
            guard let server = servers.server(id) else { throw ConnectionError.noPassword }
            return try await listRemote(server, RemotePath(bytes: bytes))
        }
    }

    /// Turns connection failures into the right prompt.
    private func handle(_ error: Error, for location: BrowseLocation) {
        let server = servers.server(location.serverID)
        switch error {
        case let ssh as SSHError where ssh.isChangedHostKey:
            self.error = "The server's host key has changed, so Blit won't connect. \(ssh)"
        case SSHError.hostKeyRejected(_, _, let presented, let known):
            if let server { trustRequest = TrustRequest(server: server, presented: presented, known: known) }
            self.error = "Waiting for you to verify the server's identity."
        case SSHError.authenticationFailed where server?.usesKey == true:
            self.error = "\(server?.displayName ?? "The server") didn't accept the key file. Check that its public key is in ~/.ssh/authorized_keys on the server, or edit the server to choose another key."
        case SSHError.authenticationFailed, ConnectionError.noPassword:
            passwordRequest = server
            self.error = "Blit needs the password for \(server?.displayName ?? "this server")."
        default:
            self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    private func listRemote(_ server: ServerConfig, _ path: RemotePath) async throws -> [FileItem] {
        let client = try await connections.browseClient(for: server)
        let folder = path.bytes.isEmpty ? RemotePath(".") : path
        let entries = try await client.list(folder)
        let base = path.bytes.isEmpty ? RemotePath("") : path
        return entries.compactMap { entry in
            let a = entry.attributes
            guard a.isDirectory || a.isRegularFile else { return nil }
            if !showHidden, entry.filename.bytes.first == UInt8(ascii: ".") { return nil }
            let name = TransferPlan.localName(entry.filename)
            let ext = (name as NSString).pathExtension
            return FileItem(location: .remote(server.id, base.appending(entry.filename)), name: name,
                            isDirectory: a.isDirectory,
                            modified: a.modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? .distantPast,
                            size: a.isDirectory ? -1 : Int64(a.size ?? 0),
                            kind: a.isDirectory ? "Folder" : (UTType(filenameExtension: ext)?.localizedDescription ?? "Document"))
        }
    }

    nonisolated static func listLocal(_ folder: URL, showHidden: Bool) throws -> [FileItem] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey, .contentModificationDateKey, .fileSizeKey,
                                      .localizedTypeDescriptionKey]
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys,
                                                               options: showHidden ? [] : [.skipsHiddenFiles])
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let isFolder = (v.isDirectory ?? false) && !(v.isPackage ?? false)
            let name = url.lastPathComponent
            var kind = v.localizedTypeDescription ?? (isFolder ? "Folder" : "Document")
            var partial: PartialDownload?
            // Blit's own leftovers, labelled so they aren't mistaken for broken media.
            if !isFolder, name.hasSuffix(".blitpart") {
                partial = PartialDownload.read(partPath: url.path)
                kind = partial.map { "Partial download · \(Int(($0.fraction * 100).rounded(.down)))%" } ?? "Blit partial file"
            } else if !isFolder, name.hasSuffix(".blitpart.state") {
                kind = "Blit resume data"
            }
            return FileItem(location: .local(url), name: name, isDirectory: isFolder,
                            modified: v.contentModificationDate ?? .distantPast,
                            size: isFolder ? -1 : Int64(v.fileSize ?? 0), kind: kind, partial: partial)
        }
    }
}
