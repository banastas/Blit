// Quick Look (PRD R2.17): Space (or ⌘Y) previews the selection, as in Finder.
// Local files preview in place; small files on a server are downloaded to a
// temporary folder first.

import AppKit
import BlitRemote
import BlitSFTP
import Foundation

extension BrowserModel {
    /// Largest server file Quick Look downloads to preview.
    static let remotePreviewLimit: Int64 = 64 << 20

    /// The browser in the front window's active pane, and that window: where
    /// Space goes (set by ContentView).
    @MainActor static weak var active: BrowserModel?
    @MainActor static weak var activeWindow: NSWindow?
    /// Tells the window a pane was clicked or right-clicked (to make it active).
    @MainActor static var onInteraction: ((BrowserModel) -> Void)?
    /// The other pane of a two-pane window (nil with one pane), and swapping
    /// the two panes' folders (set by ContentView).
    @MainActor static var oppositePane: ((BrowserModel) -> BrowserModel?)?
    @MainActor static var swapPanes: (() -> Void)?

    /// What the Quick Look panel holds: just the file shown. Moving between
    /// files goes through the list's selection (↑/↓), so the two stay in step.
    var previewURLs: [URL] { previewURL.map { [$0] } ?? [] }

    /// Files Quick Look can show: any local file, and server files small
    /// enough to download for a preview. Folders are skipped.
    func isPreviewable(_ item: FileItem) -> Bool {
        !item.isDirectory && (item.location.localURL != nil || item.size <= Self.remotePreviewLimit)
    }

    /// ↑/↓ while Quick Look is open: select the previous or next previewable
    /// file in the list; the panel follows the selection.
    func movePreview(by step: Int) {
        let rows = self.rows
        let selected = rows.indices.filter { selection.contains(rows[$0].id) }
        guard let start = step > 0 ? selected.last : selected.first else {
            // Nothing selected (e.g. the previewed file vanished in a refresh):
            // start from the first previewable file.
            if let first = rows.first(where: isPreviewable) { selection = [first.id] }
            return
        }
        var index = start + step
        while rows.indices.contains(index) {
            if isPreviewable(rows[index]) {
                selection = [rows[index].id]
                return
            }
            index += step
        }
    }

    func togglePreview() {
        if previewURL != nil {
            previewURL = nil
        } else if previewLoading != nil {
            previewLoading = nil   // still downloading: don't open when it arrives
        } else {
            previewSelection()
        }
    }

    /// Removes files downloaded for Quick Look (at launch and quit).
    static func cleanUpPreviewDownloads() {
        try? FileManager.default.removeItem(at: previewFolder)
    }

    private static var previewFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("Blit Quick Look", isDirectory: true)
    }

    /// Shows the first selected item in Quick Look (or follows the selection
    /// while the panel is open).
    func previewSelection() {
        guard let item = selectedItems.first else {
            // The selection is gone (e.g. the file vanished in a refresh): close.
            previewURL = nil
            previewLoading = nil
            return
        }
        switch item.location {
        case .local(let url):
            previewURL = url
        case .remote(let id, let bytes):
            guard !item.isDirectory, let server = servers.server(id) else { return }
            guard item.size <= Self.remotePreviewLimit else {
                previewURL = nil
                report("“\(item.name)” is \(item.size.formatted(.byteCount(style: .file))). Quick Look previews server files up to \(Self.remotePreviewLimit.formatted(.byteCount(style: .file))); download it to preview it.", action: "QUICK LOOK")
                return
            }
            // Already downloaded this session: show it again without re-downloading.
            if let cached = previewDownloads.first(where: { $0.location == item.location })?.url,
               FileManager.default.fileExists(atPath: cached.path) {
                previewURL = cached
                return
            }
            guard previewLoading != item.location else { return }   // already on its way
            previewLoading = item.location
            let job = operations.transfers.beginOperation("PREVIEW", done: "READY", items: [item.name],
                                                          destination: "Quick Look", link: "SFTP")
            Task {
                do {
                    let url = try await downloadForPreview(RemotePath(bytes: bytes), name: item.name,
                                                           size: UInt64(max(0, item.size)), from: server)
                    job.filesFinished = 1
                    rememberPreviewDownload(item.location, url)
                    // Still wanted? (Space may have cancelled, or the selection moved on.)
                    if previewLoading == item.location, selection.contains(item.location) { previewURL = url }
                } catch {
                    job.failures.append("\(item.name): \(error)")
                    report(FileOperations.describe(error), action: "QUICK LOOK")
                }
                if previewLoading == item.location { previewLoading = nil }
                operations.transfers.finishOperation(job)
            }
        }
    }

    /// Keeps the last 20 preview downloads; older ones are deleted.
    private func rememberPreviewDownload(_ location: BrowseLocation, _ url: URL) {
        previewDownloads.removeAll { $0.location == location }
        previewDownloads.append((location, url))
        while previewDownloads.count > 20 {
            let old = previewDownloads.removeFirst()
            try? FileManager.default.removeItem(at: old.url.deletingLastPathComponent())
        }
    }

    private func downloadForPreview(_ path: RemotePath, name: String, size: UInt64, from server: ServerConfig) async throws -> URL {
        let client = try await connections.browseClient(for: server)
        let folder = Self.previewFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name)
        let file = try PartFile.create(at: target.path, size: size)
        defer { file.close() }
        if size > 0 { _ = try await client.download(path, range: 0..<size, into: file) { _ in } }
        return target
    }
}
