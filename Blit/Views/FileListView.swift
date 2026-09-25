// Finder-style file list: native Table with alternating rows, newest first by
// default, monospaced digits for sizes and dates (PRD R2.4–R2.6).

import SwiftUI
import UniformTypeIdentifiers

struct FileListView: View {
    @Bindable var browser: BrowserModel
    @State private var selection = Set<FileItem.ID>()

    var body: some View {
        Group {
            if let error = browser.error {
                ContentUnavailableView("Can't Open Folder", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if browser.current == nil {
                ContentUnavailableView("Choose a Location", systemImage: "sidebar.left")
            } else {
                table
            }
        }
    }

    private var table: some View {
        Table(browser.sortedItems, selection: $selection, sortOrder: $browser.sortOrder) {
            TableColumn("Name", value: \.name) { item in
                Label {
                    Text(item.name).lineLimit(1)
                } icon: {
                    Image(nsImage: IconCache.shared.icon(for: item))
                        .resizable()
                        .frame(width: 16, height: 16)
                }
            }
            .width(min: 180, ideal: 360)

            TableColumn("Date Modified", value: \.modified) { item in
                Text(item.modified, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 160)

            TableColumn("Size", value: \.size) { item in
                Text(item.isDirectory ? "—" : item.size.formatted(.byteCount(style: .file)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Kind", value: \.kind) { item in
                Text(item.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: FileItem.ID.self) { locations in
            let urls = locations.compactMap(\.localURL)
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                .disabled(urls.isEmpty)
        } primaryAction: { locations in
            // Double-click / Return: open a folder in place, or a local file in its app.
            guard let location = locations.first, let item = browser.items.first(where: { $0.location == location }) else { return }
            if item.isDirectory {
                browser.open(location)
            } else if let url = location.localURL {
                NSWorkspace.shared.open(url)
            }
        }
        .overlay {
            if browser.isLoading, browser.items.isEmpty {
                ProgressView()
            } else if browser.items.isEmpty {
                Text("Empty Folder").foregroundStyle(.tertiary)
            }
        }
        .onChange(of: browser.current) { selection.removeAll() }
    }
}

/// File icons by type, cached (per-file icons are slow over SMB).
@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]

    func icon(for item: FileItem) -> NSImage {
        let key = item.isDirectory ? "/folder" : (item.name as NSString).pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let type = item.isDirectory ? UTType.folder : (UTType(filenameExtension: key) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}
