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
    var id: BrowseLocation { location }
}

/// Asking for a name: a new folder, or a new name for an item.
struct NamePrompt: Identifiable {
    enum Kind { case newFolder, rename(FileItem) }
    let id = UUID()
    let kind: Kind
    var name: String

    var title: String {
        switch kind {
        case .newFolder: "New Folder"
        case .rename(let item): "Rename “\(item.name)”"
        }
    }
}

extension NamePrompt.Kind {
    var isNewFolder: Bool {
        if case .newFolder = self { return true }
        return false
    }
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
    var sortOrder = [KeyPathComparator(\FileItem.modified, order: .reverse)]
    var trustRequest: TrustRequest?
    var passwordRequest: ServerConfig?
    /// Show names starting with "." (View › Show Hidden Files, ⇧⌘.).
    private(set) var showHidden = false
    var selection = Set<BrowseLocation>()
    var namePrompt: NamePrompt?
    /// Items waiting for the user to confirm a permanent delete.
    var deleteRequest: [FileItem]?
    var operationError: String?

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
        current = location
        isLoading = true
        error = nil
        Task {
            do {
                let listed: [FileItem]
                switch location {
                case .local(let url):
                    let hidden = showHidden
                    listed = try await Task.detached { try Self.listLocal(url, showHidden: hidden) }.value
                case .remote(let id, let bytes):
                    guard let server = servers.server(id) else { throw ConnectionError.noPassword }
                    listed = try await listRemote(server, RemotePath(bytes: bytes))
                }
                guard location == current else { return }
                items = listed
                selection.formIntersection(listed.map(\.location))
                remember(location)
            } catch {
                guard location == current else { return }
                items = []
                handle(error, for: location)
            }
            isLoading = false
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
            return FileItem(location: .local(url), name: url.lastPathComponent, isDirectory: isFolder,
                            modified: v.contentModificationDate ?? .distantPast,
                            size: isFolder ? -1 : Int64(v.fileSize ?? 0),
                            kind: v.localizedTypeDescription ?? (isFolder ? "Folder" : "Document"))
        }
    }
}
