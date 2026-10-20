// The file list for one folder, local or on a server: loading off the main
// thread, sorting (newest first by default, PRD R2.4), back/forward history,
// and the prompts a server connection can need (trust, password).

import AppKit
import BlitRemote
import BlitSFTP
import Foundation
import Observation
import UniformTypeIdentifiers

/// How a row stands against the other pane's folder (View › Compare Panes).
struct PaneComparison: Hashable {
    enum Kind: Hashable {
        /// Not in the other folder.
        case onlyHere
        /// There too: a folder of the name, or a file of the size.
        case same
        /// There too, the same size, and that copy was verified by SHA-256.
        case verifiedThere
        /// Being downloaded there: a resumable `.blitpart` of it.
        case partlyThere
        /// There too, but a different size, or a file where this is a folder.
        case differs
    }
    let kind: Kind
    let help: String

    var text: String {
        switch kind {
        case .onlyHere: "only here"
        case .same: "= same"
        case .verifiedThere: "verified there"
        case .partlyThere: "partly there"
        case .differs: "≠ differs"
        }
    }
}

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
    private(set) var items: [FileItem] = [] {
        didSet {
            rowsCache = nil
            nameIndexCache = nil
            itemsVersion &+= 1
        }
    }
    /// Counts changes to `items`, for whoever compares against this folder.
    private(set) var itemsVersion = 0
    @ObservationIgnored private var nameIndexCache: [String: FileItem]?
    private(set) var error: String?
    private(set) var isLoading = false
    /// Newest first unless this folder was sorted otherwise before (SortMemory).
    var sortOrder = SortMemory.standard {
        didSet {
            rowsCache = nil
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
    private(set) var expanded = Set<BrowseLocation>() {
        didSet { rowsCache = nil }
    }
    private(set) var children: [BrowseLocation: [FileItem]] = [:] {
        didSet { rowsCache = nil }
    }
    private(set) var loadingChildren = Set<BrowseLocation>()
    /// The item whose name is being edited in place, if any.
    var renaming: BrowseLocation?
    /// Items in the Rename N Items sheet.
    var batchRenameItems: [FileItem]?
    /// The item shown in Get Info (⌘I).
    var infoItem: FileItem?
    /// Shoot folders in the Back Up Edits sheet (PRD R2.26).
    var editBackupFolders: [URL]?
    /// A camera card in the import sheet (PRD R5.12).
    var cardImport: URL?
    /// Find in Archive is up (PRD R4.6).
    var findingInArchive = false
    /// A server folder to set watch mode up for (PRD R5.10).
    var watchRequest: BrowseLocation?
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
    /// Where the AppKit list was scrolled when it last showed this pane (a tab
    /// switch shows another tab's pane in the same list).
    @ObservationIgnored var listScrollOrigin: NSPoint?
    /// What this folder listed when it was last left (FolderVisits): anything
    /// else is new since then. Fixed for the visit; nil on a first visit.
    @ObservationIgnored private(set) var seenNames: Set<String>?
    /// The AppKit list showing this pane, which takes the keyboard when asked
    /// (requestKeyboardFocus), and whether it was asked before one showed it.
    @ObservationIgnored weak var keyboardTarget: (any ListKeyboardTarget)?
    @ObservationIgnored var wantsKeyboard = false
    /// Server files already downloaded for Quick Look this session, oldest first.
    @ObservationIgnored var previewDownloads: [(location: BrowseLocation, url: URL)] = []
    /// Folders' summary pages for Quick Look, and when each was made.
    @ObservationIgnored var folderSummaryPages: [BrowseLocation: (made: Date, url: URL)] = [:]

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
        guard recents.first != location else { return }
        recents.removeAll { $0 == location }
        recents.insert(location, at: 0)
        if recents.count > 20 { recents.removeLast(recents.count - 20) }
        if let data = try? JSONEncoder().encode(recents) { UserDefaults.standard.set(data, forKey: Self.recentsKey) }
    }

    var sortedItems: [FileItem] { items.sorted(using: sortOrder) }

    /// The rows to show: this folder's items, with the contents of expanded
    /// folders nested under them, each level sorted. Kept until one of those
    /// changes: sorting thousands of files on every read (the list, the path
    /// bar's count, the menus) slowed tab switches.
    var rows: [FileItem] {
        // Read every input, cached or not, so whoever reads the rows hears when they change.
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let (items, sortOrder, expanded, children) = (items, sortOrder, expanded, children)
        if let rowsCache { return rowsCache }
        func matches(_ item: FileItem) -> Bool { query.isEmpty || item.name.localizedStandardContains(query) }
        // With a search, a folder stays when it matches or holds a match (in an expanded folder).
        func rows(_ list: [FileItem], depth: Int) -> [FileItem] {
            var result: [FileItem] = []
            for var item in list.sorted(using: sortOrder) {
                item.depth = depth
                var nested: [FileItem] = []
                if item.isDirectory, expanded.contains(item.location), let inside = children[item.location] {
                    nested = rows(inside, depth: depth + 1)
                }
                guard matches(item) || !nested.isEmpty else { continue }
                result.append(item)
                result += nested
            }
            return result
        }
        let built = rows(items, depth: 0)
        rowsCache = built
        return built
    }
    @ObservationIgnored private var rowsCache: [FileItem]? {
        didSet { if rowsCache == nil { rowIndexCache = nil } }
    }

    /// Where each row is in `rows`, kept as long as the rows are: the AppKit
    /// list finds rows by location, and indexing 10,000 took 12 ms a tab switch.
    var rowIndex: [BrowseLocation: Int] {
        let rows = rows
        if let rowIndexCache { return rowIndexCache }
        let built = Dictionary(rows.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        rowIndexCache = built
        return built
    }
    @ObservationIgnored private var rowIndexCache: [BrowseLocation: Int]?

    /// The toolbar search (⌘F): filters the listing (and expanded folders) by
    /// name, ignoring case and accents. Cleared when moving to another folder.
    var searchText = "" {
        didSet { rowsCache = nil }
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
            if let listed {
                if children[folder] != listed { children[folder] = listed }
            } else {
                expanded.remove(folder)
                children[folder] = nil
            }
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
        // A cloud folder's own top level is "iCloud Drive", not com~apple~CloudDocs.
        if let url = current.localURL, let cloud = CloudFolders.folder(containing: url),
           cloud.url.path == url.lexicalPath { return cloud.name }
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

    private static let partSuffix = ".blitpart"

    /// The item named `name` here (ignoring case, as APFS and SMB do).
    func item(named name: String) -> FileItem? {
        if nameIndexCache == nil {
            nameIndexCache = Dictionary(items.map { ($0.name.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        }
        return nameIndexCache?[name.lowercased()]
    }

    /// With View › Compare Panes on: how `item` (in this folder, not an
    /// expanded one) stands against the other pane's folder.
    func comparison(for item: FileItem) -> PaneComparison? {
        guard item.depth == 0, Panes.shared.comparing, let other = Panes.shared.other(than: self),
              let there = other.current, there != current else { return nil }
        let folder = other.title.isEmpty ? there.lastComponent : other.title
        let onlyHere = PaneComparison(kind: .onlyHere, help: "Not in “\(folder)”")
        // A partial download stands for the file it will be (its ◐ says the rest).
        if !item.isDirectory, item.name.hasSuffix(Self.partSuffix) {
            return other.item(named: String(item.name.dropLast(Self.partSuffix.count))) == nil ? onlyHere : nil
        }
        guard let twin = other.item(named: item.name) else {
            if !item.isDirectory, let part = other.item(named: item.name + Self.partSuffix), !part.isDirectory {
                let done = part.partial.map { " (\(Int64($0.done).formatted(.byteCount(style: .file))) so far)" } ?? ""
                return PaneComparison(kind: .partlyThere, help: "Being downloaded to “\(folder)”\(done)")
            }
            return onlyHere
        }
        if twin.isDirectory != item.isDirectory {
            return PaneComparison(kind: .differs, help: "“\(folder)” has a \(twin.isDirectory ? "folder" : "file") of this name")
        }
        if item.isDirectory { return PaneComparison(kind: .same, help: "“\(folder)” has a folder of this name too") }
        guard twin.size == item.size else {
            let size = twin.size.formatted(.byteCount(style: .file))
            return PaneComparison(kind: .differs, help: "In “\(folder)” too, but a different size there (\(size))")
        }
        if let url = twin.location.localURL, let entry = VerifiedIndex.shared.entry(for: url, size: twin.size) {
            return PaneComparison(kind: .verifiedThere, help: "In “\(folder)” too, the same size; \(entry.summary.prefix(1).lowercased() + entry.summary.dropFirst())")
        }
        return PaneComparison(kind: .same, help: "In “\(folder)” too, the same size")
    }

    /// With Compare Panes on: the rows the other folder lacks or has
    /// differently, for the path bar ("4 only here · 1 differs"); nil if none.
    func comparisonSummary() -> String? {
        guard Panes.shared.comparing, let other = Panes.shared.other(than: self) else { return nil }
        _ = other.itemsVersion   // observed: item(named:) reads through a cache
        var onlyHere = 0, differs = 0
        for item in rows where item.depth == 0 {
            switch comparison(for: item)?.kind {
            case .onlyHere: onlyHere += 1
            case .differs: differs += 1
            default: break
            }
        }
        let parts = [onlyHere > 0 ? "\(onlyHere) only here" : nil, differs > 0 ? "\(differs) differ\(differs == 1 ? "s" : "")" : nil]
        return parts.contains { $0 != nil } ? parts.compactMap { $0 }.joined(separator: " · ") : nil
    }

    /// Whether `item` (in this folder, not an expanded one) wasn't here when the
    /// folder was last left.
    func isNew(_ item: FileItem) -> Bool {
        guard item.depth == 0, let seenNames else { return false }
        return !seenNames.contains(item.name)
    }

    /// This folder is being left (another folder, a closed tab, quitting):
    /// what it lists is remembered for the next visit.
    func noteLeaving() {
        guard let current, !items.isEmpty else { return }
        FolderVisits.left(current, names: items.map(\.name))
    }

    /// Names this pane made itself (a rename, a new folder) aren't new.
    func noteOwn(_ name: String) {
        seenNames?.insert(name)
    }

    /// Reloads `models` now, or once the mouse button is up: a listing that
    /// changes under a drag moves the rows (and the folder) under the pointer.
    static func reloadWhenIdle(_ models: [BrowserModel]) {
        guard !models.isEmpty else { return }
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return models.forEach { $0.reload() } }
        Task { @MainActor in
            while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(250)) }
            models.forEach { $0.reload() }
        }
    }

    private func show(_ location: BrowseLocation) {
        if location != current {
            noteLeaving()
            seenNames = FolderVisits.seen(location)
            searchText = ""
            // A new folder: start collapsed, showing the last listing (if any)
            // at once while a fresh one loads.
            expanded = []
            children = [:]
            items = connections.listings[location] ?? []
            restoringSort = true
            sortOrder = SortMemory.order(for: location)
            restoringSort = false
        }
        // Reloading the folder shown is quiet until something changed: every
        // write here redraws the list and rebuilds its drop target, which a
        // drag over it (or a transfer finishing into it) mustn't trip over.
        let quiet = location == current && !items.isEmpty
        if current != location { current = location }
        if !quiet { isLoading = true }
        if error != nil { error = nil }
        Task {
            do {
                let listed = try await list(location)
                guard location == current else { return }
                if listed != items { items = listed }
                if connections.listings.count > 500 { connections.listings.removeAll() }
                connections.listings[location] = listed
                if !expanded.isEmpty { await reloadExpanded() }
                guard location == current else { return }
                let kept = selection.intersection(rows.map(\.location))
                if kept != selection { selection = kept }
                if let renaming, !rows.contains(where: { $0.location == renaming }) {
                    RenameLog.note("ended by a reload: the file isn't in the folder's \(rows.count) rows now (\(rows.contains { $0.name == renaming.lastComponent } ? "its name is, at another path" : "nor its name"))")
                    self.renaming = nil
                }
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
            if isLoading { isLoading = false }
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
