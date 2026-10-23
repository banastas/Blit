// Free space in drop highlights (PRD R2.10): how much the drag in progress
// carries, by the volume it comes from, so a drop target can say "1.2 TB free
// → 0.9 TB after" or that it won't fit. A drag from a Blit list is measured as
// it starts (its rows' sizes; folders summed in the background, on a server
// through the pane's browse connection, as Get Info does); Finder's files when
// they first come over Blit. Until a folder is summed, or if it can't be, a
// target shows just the free space.

import AppKit
import BlitRemote
import BlitSFTP
import Observation
import UniformTypeIdentifiers

@MainActor
@Observable
final class DragSize {
    static let shared = DragSize()

    /// Bytes by where they come from: a volume ("/Volumes/SSD", "/" for the
    /// startup disk) or "server". Nil while the drag is being measured, or
    /// when it couldn't be.
    private(set) var bytes: [String: Int64]?
    /// The drag measured: the drag pasteboard's change count then.
    @ObservationIgnored private var drag = -1
    @ObservationIgnored private var task: Task<Void, Never>?

    static func source(of location: BrowseLocation) -> String {
        location.localURL.map(FreeSpace.volumeRoot) ?? "server"
    }

    /// A drag of `items` (rows of `browser`) began.
    func measure(_ items: [FileItem], in browser: BrowserModel) {
        restart()
        var known: [String: Int64] = [:]
        for item in items where !item.isDirectory { known[Self.source(of: item.location), default: 0] += max(item.size, 0) }
        let folders = items.filter(\.isDirectory).map(\.location)
        guard !folders.isEmpty else { return bytes = known }
        let connections = browser.connections, servers = browser.servers, hidden = browser.showHidden
        task = Task { [weak self] in
            var total = known
            for folder in folders {
                guard let size = await Self.size(of: folder, connections: connections, servers: servers, includeHidden: hidden),
                      !Task.isCancelled else { return }
                total[Self.source(of: folder), default: 0] += size
            }
            self?.bytes = total
        }
    }

    /// A drag came over one of Blit's drop targets: if it's one not measured
    /// yet (files from Finder), measure it.
    func note(_ pasteboard: NSPasteboard) {
        guard pasteboard.changeCount != drag,
              pasteboard.types?.contains(NSPasteboard.PasteboardType(UTType.blitLocations.identifier)) != true else { return }
        restart(pasteboard.changeCount)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        task = Task { [weak self] in
            var total: [String: Int64] = [:]
            for url in urls {
                guard let size = await Self.localSize(url), !Task.isCancelled else { return }
                total[FreeSpace.volumeRoot(of: url), default: 0] += size
            }
            self?.bytes = total
        }
    }

    private func restart(_ changeCount: Int = NSPasteboard(name: .drag).changeCount) {
        task?.cancel()
        task = nil
        drag = changeCount
        if bytes != nil { bytes = nil }
    }

    private static func size(of folder: BrowseLocation, connections: ConnectionManager, servers: ServerStore, includeHidden: Bool) async -> Int64? {
        switch folder {
        case .local(let url):
            return await localSize(url)
        case .remote(let id, let path):
            guard let server = servers.server(id) else { return nil }
            // Give up on a tree that takes long to list (it only means no estimate).
            return await withTaskGroup(of: Int64?.self) { group in
                group.addTask {
                    guard let client = try? await connections.browseClient(for: server),
                          let tree = try? await remoteTree(at: RemotePath(bytes: path), using: client, includeHidden: includeHidden) else { return nil }
                    return Int64(clamping: tree.files.saturatingSum(\.size))
                }
                group.addTask {
                    try? await Task.sleep(for: .seconds(15))
                    return nil
                }
                let first = await group.next() ?? nil
                group.cancelAll()
                return first
            }
        }
    }

    /// A local file's size, or a folder's files' added up (at most 200,000 of them).
    private static func localSize(_ url: URL) async -> Int64? {
        await Task.detached(priority: .utility) { () -> Int64? in
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey]
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            guard values.isDirectory == true else { return Int64(values.fileSize ?? 0) }
            var total: Int64 = 0, files = 0
            let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys))
            while let next = walker?.nextObject() as? URL {
                guard let values = try? next.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
                total += Int64(values.fileSize ?? 0)
                files += 1
                if files > 200_000 || Task.isCancelled { return nil }
            }
            return total
        }.value
    }

    #if DEBUG
    /// Whether the drag is still being measured (the tests wait).
    var measuring: Bool { task != nil && bytes == nil }
    #endif
}

/// What a drop into `destination` would leave free, in the words a drop
/// target shows. Nil where there's nothing to say: a server, a cloud folder
/// (the Mac's free space would read as the cloud's), free space not known yet.
@MainActor
enum DropSpace {
    struct Summary: Equatable {
        let text: String
        let fits: Bool
    }

    /// `compact` for a sidebar row: "→ 0.9 TB free"; else "1.2 TB free → 0.9 TB after".
    static func summary(into destination: BrowseLocation, compact: Bool) -> Summary? {
        guard let url = destination.localURL, CloudFolders.folder(containing: url) == nil,
              let free = FreeSpace.shared.free(at: url) else { return nil }
        func size(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file)) }
        // What comes from the same volume takes no room: a move there is a
        // rename, and a copy an APFS clone.
        let volume = FreeSpace.volumeRoot(of: url)
        let needed = DragSize.shared.bytes.map { $0.filter { $0.key != volume }.values.reduce(0, +) } ?? 0
        guard needed > 0 else { return Summary(text: "\(size(free)) free", fits: true) }
        guard needed <= free else {
            return Summary(text: compact ? "Needs \(size(needed))" : "Needs \(size(needed)), \(size(free)) free", fits: false)
        }
        return Summary(text: compact ? "→ \(size(free - needed)) free" : "\(size(free)) free → \(size(free - needed)) after", fits: true)
    }
}
