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
        guard let start = step > 0 ? selected.last : selected.first else { return }
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
        } else {
            previewSelection()
        }
    }

    /// Shows the first selected item in Quick Look (or follows the selection
    /// while the panel is open).
    func previewSelection() {
        guard let item = selectedItems.first else { return }
        switch item.location {
        case .local(let url):
            previewURL = url
        case .remote(let id, let bytes):
            guard !item.isDirectory, let server = servers.server(id) else { return }
            guard item.size <= Self.remotePreviewLimit else {
                previewURL = nil
                operationError = "“\(item.name)” is \(item.size.formatted(.byteCount(style: .file))). Quick Look previews server files up to \(Self.remotePreviewLimit.formatted(.byteCount(style: .file))); download it to preview it."
                return
            }
            let job = operations.transfers.beginOperation("PREVIEW", done: "READY", items: [item.name],
                                                          destination: "Quick Look", link: "SFTP")
            Task {
                do {
                    let url = try await downloadForPreview(RemotePath(bytes: bytes), name: item.name,
                                                           size: UInt64(max(0, item.size)), from: server)
                    job.filesFinished = 1
                    // Still wanted? (The selection may have moved on meanwhile.)
                    if selection.contains(item.location) { previewURL = url }
                } catch {
                    job.failures.append("\(item.name): \(error)")
                    operationError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
                }
                operations.transfers.finishOperation(job)
            }
        }
    }

    private func downloadForPreview(_ path: RemotePath, name: String, size: UInt64, from server: ServerConfig) async throws -> URL {
        let client = try await connections.browseClient(for: server)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("Blit Quick Look", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = folder.appendingPathComponent(name)
        let file = try PartFile.create(at: target.path, size: size)
        defer { file.close() }
        if size > 0 { _ = try await client.download(path, range: 0..<size, into: file) { _ in } }
        return target
    }
}
