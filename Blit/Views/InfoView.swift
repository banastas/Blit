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
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.headline).textSelection(.enabled).lineLimit(3)
                    Text(item.kind.uppercased()).font(HUDFont.label()).foregroundStyle(.secondary)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    key("Size")
                    if item.isDirectory, folderSize == nil {
                        HStack(spacing: 8) {
                            PixelScanner().frame(height: 8)
                            Text("CALCULATING").font(HUDFont.label()).foregroundStyle(.secondary)
                        }
                    } else {
                        Text(sizeText).textSelection(.enabled)
                    }
                }
                GridRow {
                    key("Where")
                    HStack(alignment: .firstTextBaseline) {
                        Text(whereText).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
                        PixelButton("Copy", help: "Copy the path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(whereText, forType: .string)
                        }
                    }
                }
                row("Modified", item.modified == .distantPast ? "—" : item.modified.formatted(date: .abbreviated, time: .standard))
                if let created { row("Created", created.formatted(date: .abbreviated, time: .standard)) }
            }
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

    /// A field name, as the HUD labels its rows: pixel uppercase, dim.
    private func key(_ label: String) -> some View {
        Text(label.uppercased())
            .font(HUDFont.label())
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            key(label)
            Text(value).textSelection(.enabled)
        }
    }

    /// How Blit verified the file, in a boxed panel like the transfer HUD's:
    /// always dark, pixel label, terminal text.
    @ViewBuilder private var verification: some View {
        if !item.isDirectory, let url = item.location.localURL,
           let entry = VerifiedIndex.shared.entry(for: url, size: item.size) {
            readout("✓ Verified by Blit", bright: true) {
                Text(entry.howAndWhen.uppercased())
                    .foregroundStyle(HUDColor.dim)
                    .fixedSize(horizontal: false, vertical: true)
                if let sha = entry.sha256 {
                    readoutRow("SHA256", sha)
                }
                if let source = entry.source {
                    readoutRow("From", source)
                }
            }
        } else if !item.isDirectory, item.location.localURL != nil {
            readout("· Not verified", bright: false) {
                Text("Files show a ✓ once Blit has copied them and their SHA-256 matched the source.")
                    .foregroundStyle(HUDColor.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if item.location.serverID != nil {
            readout("· On a server", bright: false) {
                Text("Blit verifies files with SHA-256 when it downloads them.")
                    .foregroundStyle(HUDColor.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func readout(_ title: String, bright: Bool, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                hudText(title.uppercased(), glyphSize: 9)
                    .font(HUDFont.label())
                    .foregroundStyle(bright ? HUDColor.bright : HUDColor.dim)
                Spacer()
                Text("BLIT://INFO").font(HUDFont.label()).foregroundStyle(HUDColor.dim)
            }
            .padding(.bottom, 2)
            content()
        }
        .font(HUDFont.terminal(17))
        .foregroundStyle(HUDColor.bright)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(HUDColor.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(HUDColor.border, lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
    }

    /// Key on the left (dim), the value after it, wrapping and selectable.
    private func readoutRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key.uppercased()).foregroundStyle(HUDColor.dim).frame(width: 52, alignment: .leading)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var icon: NSImage {
        if let url = item.location.localURL { return NSWorkspace.shared.icon(forFile: url.path) }
        return IconCache.shared.icon(for: item)
    }

    private var sizeText: String {
        if item.isDirectory { return folderSize ?? "" }
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
                let total = tree.files.saturatingSum(\.size)
                folderSize = "\(Int64(clamping: total).formatted(.byteCount(style: .file))) · \(tree.files.count) file\(tree.files.count == 1 ? "" : "s")"
            } catch {
                folderSize = "Couldn't calculate: \(error)"
            }
        }
    }
}

/// The HUD's text button, in the sheet's own colours (Get Info follows the
/// system appearance; the HUD is always dark).
private struct PixelButton: View {
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovered = false

    init(_ title: String, help: String, action: @escaping () -> Void) {
        self.title = title
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(HUDFont.label(10))
                .foregroundStyle(hovered ? .primary : .secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .overlay(Rectangle().strokeBorder(hovered ? Color.primary : Color.secondary.opacity(0.5), lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Work with no known end (a folder being totalled): a short run of lit
/// cells sweeping back and forth across the HUD's discrete cells. Still,
/// with Reduce Motion on.
private struct PixelScanner: View {
    var count = 14
    var lit = 3
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: reduceMotion)) { timeline in
            let span = count - lit
            let step = Int(timeline.date.timeIntervalSinceReferenceDate * 15) % (2 * span)
            let start = reduceMotion ? -lit : (step < span ? step : 2 * span - step)
            HStack(spacing: 2) {
                ForEach(0..<count, id: \.self) { i in
                    Rectangle()
                        .fill(i >= start && i < start + lit ? Color.primary : Color.primary.opacity(0.15))
                        .frame(width: 4)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calculating")
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
                Text(problem).font(.callout).foregroundStyle(Color.failureText)
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
