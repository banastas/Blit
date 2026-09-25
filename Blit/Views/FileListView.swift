// Finder-style file list: native Table with alternating rows, newest first by
// default, monospaced digits for sizes and dates (PRD R2.4–R2.6), with file
// management from the context menu and drag and drop (R2.12).

import SwiftUI
import UniformTypeIdentifiers

struct FileListView: View {
    @Bindable var browser: BrowserModel
    @State private var isTargeted = false

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
        .alert(browser.namePrompt?.title ?? "", isPresented: promptShown, presenting: browser.namePrompt) { prompt in
            TextField("Name", text: promptName)
            Button(prompt.kind.isNewFolder ? "Create" : "Rename") { browser.commit(browser.namePrompt ?? prompt) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(deleteTitle, isPresented: deleteShown, presenting: browser.deleteRequest) { items in
            Button("Delete", role: .destructive) { browser.confirmDelete(items) }
            Button("Cancel", role: .cancel) {}
        } message: { items in
            Text(items.contains(where: \.isDirectory)
                 ? "This can't be undone. Folders are deleted with everything in them."
                 : "This can't be undone.")
        }
        .alert("Can't Complete", isPresented: errorShown) {
            Button("OK") {}
        } message: {
            Text(browser.operationError ?? "")
        }
    }

    private var promptShown: Binding<Bool> {
        Binding(get: { browser.namePrompt != nil }, set: { if !$0 { browser.namePrompt = nil } })
    }

    private var promptName: Binding<String> {
        Binding(get: { browser.namePrompt?.name ?? "" }, set: { browser.namePrompt?.name = $0 })
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { browser.deleteRequest != nil }, set: { if !$0 { browser.deleteRequest = nil } })
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { browser.operationError != nil }, set: { if !$0 { browser.operationError = nil } })
    }

    private var deleteTitle: String {
        guard let items = browser.deleteRequest else { return "" }
        let what = items.count == 1 ? "“\(items[0].name)”" : "\(items.count) items"
        let place = browser.current?.serverID != nil ? " from the server" : ""
        return "Delete \(what)\(place) permanently?"
    }

    private var table: some View {
        Table(of: FileItem.self, selection: $browser.selection, sortOrder: $browser.sortOrder) {
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
        } rows: {
            ForEach(browser.sortedItems) { item in
                TableRow(item)
                    .draggable(payload(for: item))
                    .dropDestination(for: TransferPayload.self) { payloads in
                        _ = drop(payloads.flatMap(\.locations), onto: item)
                    }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .dropDestination(for: TransferPayload.self) { payloads, _ in
            drop(payloads.flatMap(\.locations), onto: nil)
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(.primary)
                    .padding(3)
                    .allowsHitTesting(false)
            }
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { locations in
            menu(for: browser.items(for: locations))
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
    }

    @ViewBuilder private func menu(for items: [FileItem]) -> some View {
        if items.isEmpty {
            Button("New Folder") { browser.promptNewFolder() }
            Divider()
            Button("Paste") { browser.paste(move: false) }
                .disabled(!browser.operations.canPaste)
        } else {
            let urls = items.compactMap(\.location.localURL)
            if items.count == 1, items[0].isDirectory {
                Button("Open") { browser.open(items[0].location) }
            }
            if !urls.isEmpty {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }
            }
            Divider()
            Button("New Folder") { browser.promptNewFolder() }
            if items.count == 1 {
                Button("Rename…") { browser.promptRename(items[0]) }
            }
            if urls.count == items.count {
                Button("Duplicate") { browser.duplicate(items) }
            }
            Divider()
            Button("Cut") { browser.copy(items, cut: true) }
            Button("Copy") { browser.copy(items, cut: false) }
            Button("Paste") { browser.paste(move: false) }
                .disabled(!browser.operations.canPaste)
            Divider()
            Button(browser.deleteTitle(for: items), role: .destructive) { browser.requestDelete(items) }
        }
    }

    /// Drops onto a folder row go into that folder; anywhere else, into this one.
    private func drop(_ sources: [BrowseLocation], onto item: FileItem?) -> Bool {
        let folder = item?.isDirectory == true ? item : nil
        guard let target = folder?.location ?? browser.current else { return false }
        let sources = sources.filter { $0 != target }
        guard !sources.isEmpty else { return false }
        browser.drop(sources, into: target, name: folder?.name ?? browser.title)
        return true
    }

    /// Dragging a selected row drags the whole selection, in list order.
    private func payload(for item: FileItem) -> TransferPayload {
        let items = browser.selection.contains(item.id) ? browser.selectedItems : [item]
        return TransferPayload(locations: items.map(\.location), folders: items.filter(\.isDirectory).map(\.location))
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
