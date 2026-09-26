// Get Info (⌘I, PRD R2.12): what an item is, where it lives, and, for files
// Blit copied, how they were verified: the method, when, the SHA-256 and the
// source, from the transfer log.

import AppKit
import BlitRemote
import BlitSFTP
import SwiftUI

struct InfoView: View {
    let item: FileItem
    let browser: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var folderSize: String?
    @State private var created: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.headline).textSelection(.enabled).lineLimit(3)
                    Text(item.kind).foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Size", sizeText)
                GridRow {
                    Text("Where").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    HStack(alignment: .firstTextBaseline) {
                        Text(whereText).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(whereText, forType: .string)
                        }
                        .controlSize(.small)
                    }
                }
                row("Modified", item.modified == .distantPast ? "—" : item.modified.formatted(date: .abbreviated, time: .standard))
                if let created { row("Created", created.formatted(date: .abbreviated, time: .standard)) }
            }
            Divider()
            verification
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await load() }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }

    @ViewBuilder private var verification: some View {
        if !item.isDirectory, let url = item.location.localURL,
           let entry = VerifiedIndex.shared.entry(for: url, size: item.size) {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("Verified by Blit").fontWeight(.semibold)
                } icon: {
                    Image(nsImage: PixelGlyph.check.image(size: 11))
                }
                Text(entry.howAndWhen).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let sha = entry.sha256 {
                    Text("SHA-256 \(sha)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let source = entry.source {
                    Text("From \(source)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        } else if !item.isDirectory, item.location.localURL != nil {
            Text("Not verified by Blit. Files show a ✓ once Blit has copied them and their SHA-256 matched the source.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if item.location.serverID != nil {
            Text("On a server. Blit verifies files with SHA-256 when it downloads them.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var icon: NSImage {
        if let url = item.location.localURL { return NSWorkspace.shared.icon(forFile: url.path) }
        return IconCache.shared.icon(for: item)
    }

    private var sizeText: String {
        if item.isDirectory { return folderSize ?? "Calculating…" }
        let bytes = item.size.formatted(.number)
        return "\(item.size.formatted(.byteCount(style: .file))) (\(bytes) bytes)"
    }

    private var whereText: String {
        switch item.location {
        case .local(let url): return url.path
        case .remote(let id, let bytes):
            let server = browser.servers.server(id)?.displayName ?? "server"
            return "\(server):\(RemotePath(bytes: bytes).description)"
        }
    }

    private func load() async {
        switch item.location {
        case .local(let url):
            created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            guard item.isDirectory else { return }
            let total = await Task.detached { () -> (bytes: Int64, files: Int) in
                var bytes: Int64 = 0
                var files = 0
                let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey]
                let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys)
                while let next = walker?.nextObject() as? URL {
                    guard let v = try? next.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
                    bytes += Int64(v.fileSize ?? 0)
                    files += 1
                }
                return (bytes, files)
            }.value
            folderSize = "\(total.bytes.formatted(.byteCount(style: .file))) · \(total.files) file\(total.files == 1 ? "" : "s")"
        case .remote(let id, let bytes):
            guard item.isDirectory, let server = browser.servers.server(id) else { return }
            do {
                let client = try await browser.connections.browseClient(for: server)
                let tree = try await remoteTree(at: RemotePath(bytes: bytes), using: client, includeHidden: browser.showHidden)
                let total = tree.files.reduce(UInt64(0)) { $0 + $1.size }
                folderSize = "\(Int64(total).formatted(.byteCount(style: .file))) · \(tree.files.count) file\(tree.files.count == 1 ? "" : "s")"
            } catch {
                folderSize = "Couldn't calculate: \(error)"
            }
        }
    }
}

/// Go to Folder (⇧⌘G): type a path. On a server pane it can be a path on that
/// server ("files/downloads" or "/home/user/files"); "~" and "/Volumes/…"
/// always mean this Mac.
struct GoToFolderView: View {
    let browser: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var path = ""
    @State private var onServer = false
    @State private var problem: String?

    private var server: ServerConfig? { browser.servers.server(browser.current?.serverID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Folder").font(.headline)
            TextField(onServer ? "files/downloads" : "/Volumes/Drive/Folder or ~/Downloads", text: $path)
                .textFieldStyle(.roundedBorder)
                .onSubmit(go)
            if let server {
                Picker("", selection: $onServer) {
                    Text("On this Mac").tag(false)
                    Text("On \(server.displayName)").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if let problem {
                Text(problem).font(.callout).foregroundStyle(Color.failure)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Go", action: go).keyboardShortcut(.defaultAction).disabled(path.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { onServer = server != nil }
    }

    private func go() {
        let text = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let local = !onServer || text.hasPrefix("~") || text.hasPrefix("/Volumes/")
        if local {
            let url = URL(fileURLWithPath: (text as NSString).expandingTildeInPath).standardizedFileURL
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else {
                problem = "There's no folder at \(url.path)."
                return
            }
            if isFolder.boolValue {
                browser.open(.local(url))
            } else {
                // A file: open its folder with the file selected.
                browser.open(.local(url.deletingLastPathComponent()))
                browser.selection = [.local(url)]
            }
        } else if let server {
            var trimmed = text
            while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
            browser.open(.remote(server.id, RemotePath(trimmed == "~" ? "" : trimmed)))
        }
        dismiss()
    }
}
