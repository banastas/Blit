// Space on a folder (PRD R2.17): Quick Look shows a summary of it instead of
// a bare folder icon (or, on a server, nothing): its size and how many files,
// the main video's details, the largest files, and the release's .nfo. Worked
// out in the background (on a server through the browse connection, as Get
// Info does, reading only the .nfo and the first 256 KB of the largest video),
// written as a small page in Quick Look's temporary folder and shown like any
// file, so Space, Esc and ↑/↓ work as they do for files.

import BlitMedia
import BlitRemote
import BlitSFTP
import Foundation

struct FolderSummary {
    var name: String
    var bytes: Int64 = 0
    var files = 0
    var folders = 0
    /// The largest files, largest first, as paths inside the folder.
    var largest: [(path: String, size: Int64)] = []
    /// The largest video Blit can read, and what its header says.
    var video: (path: String, info: VideoInfo)?
    /// The .nfo nearest the top, decoded.
    var nfo: (path: String, text: String)?
    /// Counting stopped at `FolderSummary.fileLimit`.
    var cut = false

    static let fileLimit = 100_000
    static let nfoLimit = 256 << 10
    static let videoHead = 256 << 10

    /// Files in, largest first, and the .nfo to read: the shallowest, then by name.
    mutating func add(_ files: [(path: String, size: Int64)]) {
        self.files = files.count
        bytes = files.reduce(0) { $0 + max($1.size, 0) }
        largest = Array(files.sorted { $0.size > $1.size }.prefix(5))
    }

    static func nfoCandidate(_ files: [(path: String, size: Int64)]) -> String? {
        files.filter { $0.path.lowercased().hasSuffix(".nfo") && $0.size <= nfoLimit }
            .min { ($0.path.split(separator: "/").count, $0.path) < ($1.path.split(separator: "/").count, $1.path) }?.path
    }

    static func videoCandidate(_ files: [(path: String, size: Int64)]) -> String? {
        files.filter { VideoProbe.handles(URL(fileURLWithPath: $0.path)) }.max { $0.size < $1.size }?.path
    }

    /// An .nfo's text: UTF-8 if it is, else the DOS code page the scene writes them in (box drawing and all).
    static func decodeNFO(_ data: Data) -> String {
        let dos = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosLatinUS.rawValue)))
        let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: dos) ?? String(decoding: data, as: UTF8.self)
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map { $0.replacing(/\s+$/, with: "") }
        return lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
    }

    /// The page Quick Look shows.
    func html() -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        func size(_ bytes: Int64) -> String { bytes.formatted(.byteCount(style: .file)) }
        var body = "<h1>\(escape(name))</h1>\n"
        let counts = "\(files.formatted()) file\(files == 1 ? "" : "s")" + (folders > 0 ? " in \(folders.formatted()) folder\(folders == 1 ? "" : "s")" : "")
        body += "<p class=\"stats\">\(size(bytes)) · \(counts)\(cut ? " (counting stopped at \(Self.fileLimit.formatted()))" : "")</p>\n"
        if let video {
            body += "<h2>Video</h2>\n<p class=\"video\">\(escape(video.info.forms[0]))</p>\n"
            body += "<p class=\"dim\">\(escape(video.info.details).replacingOccurrences(of: "\n", with: "<br>"))<br>\(escape(video.path))</p>\n"
        }
        if largest.count > 1 || (largest.count == 1 && video == nil) {
            body += "<h2>Largest</h2>\n<table>\n"
            for file in largest {
                body += "<tr><td>\(escape(file.path))</td><td class=\"size\">\(size(file.size))</td></tr>\n"
            }
            body += "</table>\n"
        }
        if let nfo {
            body += "<h2>\(escape(nfo.path))</h2>\n<pre>\(escape(nfo.text))</pre>\n"
        }
        return """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(escape(name))</title><style>
        :root { color-scheme: light dark; }
        body { font: 13px -apple-system, sans-serif; margin: 26px 30px; color: #1d1d1f; background: #ffffff; }
        h1 { font-size: 19px; margin: 0 0 4px; word-break: break-all; }
        h2 { font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: .06em; color: #6e6e73; margin: 20px 0 6px; word-break: break-all; }
        .stats { font-size: 14px; margin: 0; font-variant-numeric: tabular-nums; }
        .video { font-size: 14px; font-weight: 600; margin: 0 0 4px; }
        .dim { color: #6e6e73; margin: 0; line-height: 1.45; word-break: break-all; }
        table { border-collapse: collapse; width: 100%; }
        td { padding: 4px 0; border-top: 1px solid #e5e5ea; vertical-align: top; word-break: break-all; }
        td.size { text-align: right; white-space: nowrap; padding-left: 16px; font-variant-numeric: tabular-nums; color: #6e6e73; }
        pre { font: 11px/1.2 "SF Mono", Menlo, monospace; background: #f5f5f7; padding: 12px 14px; border-radius: 8px; overflow-x: auto; margin: 0; }
        @media (prefers-color-scheme: dark) {
          body { color: #f5f5f7; background: #1e1e1e; }
          h2, .dim, td.size { color: #98989d; }
          td { border-top-color: #38383a; }
          pre { background: #2a2a2c; }
        }
        </style></head><body>
        \(body)</body></html>
        """
    }
}

extension BrowserModel {
    /// Quick Look on a folder: its summary page, made if it isn't fresh (30 s).
    func previewFolder(_ item: FileItem) {
        if let page = folderSummaryPages[item.location], Date().timeIntervalSince(page.made) < 30,
           FileManager.default.fileExists(atPath: page.url.path) {
            previewURL = page.url
            return
        }
        guard previewLoading != item.location else { return }   // already on its way
        previewLoading = item.location
        let server: ServerConfig? = if case .remote(let id, _) = item.location { servers.server(id) } else { nil }
        let job = server.map { _ in
            operations.transfers.beginOperation("SUMMARY", done: "READY", items: [item.name], destination: "Quick Look", link: "SFTP")
        }
        Task {
            do {
                let summary = try await summarize(item, on: server)
                let folder = Self.quickLookFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let page = folder.appendingPathComponent(item.name + ".html")
                try Data(summary.html().utf8).write(to: page)
                if let old = folderSummaryPages[item.location] { try? FileManager.default.removeItem(at: old.url.deletingLastPathComponent()) }
                folderSummaryPages[item.location] = (Date(), page)
                job?.filesFinished = 1
                // Still wanted? (Space may have closed it, or the selection moved on.)
                if previewLoading == item.location, selection.contains(item.location) { previewURL = page }
            } catch {
                job?.failures.append("\(item.name): \(error)")
                report(FileOperations.describe(error), action: "QUICK LOOK")
            }
            if previewLoading == item.location { previewLoading = nil }
            if let job { operations.transfers.finishOperation(job) }
        }
    }

    private func summarize(_ item: FileItem, on server: ServerConfig?) async throws -> FolderSummary {
        switch item.location {
        case .local(let url):
            let hidden = showHidden
            var (summary, video) = await Task.detached(priority: .userInitiated) { Self.walk(url, includeHidden: hidden) }.value
            summary.name = item.name
            if let video, let info = await VideoProbe.probe(url.appendingPathComponent(video)) { summary.video = (video, info) }
            return summary
        case .remote(_, let bytes):
            guard let server else { throw CocoaError(.fileNoSuchFile) }
            let client = try await connections.browseClient(for: server)
            let tree = try await remoteTree(at: RemotePath(bytes: bytes), using: client, includeHidden: showHidden)
            // Paths inside the folder: the tree's start with the folder's own name.
            var byPath: [String: RemoteFile] = [:]
            for file in tree.files { byPath[String(file.relativePath.split(separator: "/", maxSplits: 1).dropFirst().first ?? "")] = file }
            let files = byPath.map { (path: $0.key, size: Int64(clamping: $0.value.size)) }
            var summary = FolderSummary(name: item.name)
            summary.add(files)
            summary.folders = max(0, tree.directories.count - 1)
            func remote(_ path: String) -> RemoteFile? { byPath[path] }
            if let path = FolderSummary.nfoCandidate(files), let file = remote(path) {
                let url = try await downloadForPreview(file.path, name: (path as NSString).lastPathComponent, size: file.size, from: server)
                if let data = try? Data(contentsOf: url) { summary.nfo = (path, FolderSummary.decodeNFO(data)) }
            }
            // A Matroska header is at the start; an MP4's may be at the end, out of reach.
            if let path = FolderSummary.videoCandidate(files), ["mkv", "mk3d", "webm"].contains((path as NSString).pathExtension.lowercased()),
               let file = remote(path) {
                let url = try await downloadForPreview(file.path, name: (path as NSString).lastPathComponent,
                                                       size: min(file.size, UInt64(FolderSummary.videoHead)), from: server)
                if let info = await VideoProbe.probe(url) { summary.video = (path, info) }
            }
            return summary
        }
    }

    /// A local folder's summary (off the main thread): every file under it,
    /// symlinks not followed, hidden ones only if shown; and the video to read.
    nonisolated private static func walk(_ root: URL, includeHidden: Bool) -> (FolderSummary, video: String?) {
        var summary = FolderSummary(name: root.lastPathComponent)
        var files: [(path: String, size: Int64)] = []
        var folders = 0
        if let walker = FileManager.default.enumerator(atPath: root.path) {
            while let path = walker.nextObject() as? String {
                let type = walker.fileAttributes?[.type] as? FileAttributeType
                if !includeHidden, (path as NSString).lastPathComponent.hasPrefix(".") {
                    if type == .typeDirectory { walker.skipDescendants() }
                    continue
                }
                if type == .typeDirectory {
                    folders += 1
                } else if type == .typeRegular {
                    files.append((path, (walker.fileAttributes?[.size] as? NSNumber)?.int64Value ?? 0))
                    if files.count >= FolderSummary.fileLimit {
                        summary.cut = true
                        break
                    }
                }
            }
        }
        summary.add(files)
        summary.folders = folders
        if let path = FolderSummary.nfoCandidate(files), let data = try? Data(contentsOf: root.appendingPathComponent(path)) {
            summary.nfo = (path, FolderSummary.decodeNFO(data))
        }
        return (summary, FolderSummary.videoCandidate(files))
    }
}
