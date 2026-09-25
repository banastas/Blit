// Finder-style file list: native Table with alternating rows, newest first by
// default, monospaced digits for sizes and dates (PRD R2.4–R2.6), with file
// management from the context menu and drag and drop (R2.12).

import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct FileListView: View {
    @Bindable var browser: BrowserModel
    @State private var isTargeted = false
    @AppStorage("showPathBar") private var showPathBar = true

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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showPathBar, browser.current != nil { PathBar(browser: browser) }
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
        ScrollViewReader { proxy in
            tableContent
                .onChange(of: browser.selection) {
                    // Keep the file Quick Look is showing in view as ↑/↓ move through the list.
                    guard browser.previewURL != nil, let first = browser.selectedItems.first else { return }
                    proxy.scrollTo(first.id)
                }
        }
    }

    private var tableContent: some View {
        Table(of: FileItem.self, selection: $browser.selection, sortOrder: $browser.sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 4) {
                    if item.depth > 0 { Spacer().frame(width: CGFloat(item.depth) * 16) }
                    disclosure(for: item)
                    Label {
                        Text(item.name).lineLimit(1)
                    } icon: {
                        FileIcon(item: item)
                    }
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
            ForEach(browser.rows) { item in
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
            guard let location = locations.first, let item = browser.rows.first(where: { $0.location == location }) else { return }
            if item.isDirectory {
                browser.open(location)
            } else if let url = location.localURL {
                NSWorkspace.shared.open(url)
            }
        }
        .quickLookPreview($browser.previewURL, in: browser.previewURLs)
        .onChange(of: browser.selection) {
            // Like Finder: while Quick Look is open, it follows the selection.
            if browser.previewURL != nil { browser.previewSelection() }
        }
        .onKeyPress(.rightArrow) { expandSelection(true) }
        .onKeyPress(.leftArrow) { expandSelection(false) }
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
            Divider()
            Button("Refresh") { browser.reload() }
        } else {
            let urls = items.compactMap(\.location.localURL)
            if items.count == 1, items[0].isDirectory {
                Button("Open") { browser.open(items[0].location) }
            }
            Button("Quick Look") {
                browser.selection = Set(items.map(\.id))
                browser.previewURL = nil
                browser.previewSelection()
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
            Divider()
            Button("Refresh") { browser.reload() }
        }
    }

    /// The triangle that shows a folder's contents in place, like Finder's list view.
    @ViewBuilder private func disclosure(for item: FileItem) -> some View {
        if item.isDirectory {
            let open = browser.expanded.contains(item.location)
            Button {
                browser.toggleExpanded(item)
            } label: {
                Group {
                    if open, browser.loadingChildren.contains(item.location) {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(open ? 90 : 0))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 12, height: 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Hide contents" : "Show contents")
        } else {
            Spacer().frame(width: 12)
        }
    }

    /// → expands the selected folders, ← collapses them (or the folder a selected item is in).
    private func expandSelection(_ open: Bool) -> KeyPress.Result {
        let selected = browser.selectedItems
        guard !selected.isEmpty else { return .ignored }
        for item in selected {
            if item.isDirectory, open || browser.expanded.contains(item.location) {
                browser.setExpanded(item.location, open)
            } else if !open, item.depth > 0, let parent = item.location.parent {
                browser.setExpanded(parent, false)
                browser.selection = [parent]
            }
        }
        return .handled
    }

    /// Drops onto a folder row go into that folder; onto a file, into the folder
    /// it's in; anywhere else, into this one.
    private func drop(_ sources: [BrowseLocation], onto item: FileItem?) -> Bool {
        var target = browser.current
        var name = browser.title
        if let item, item.isDirectory {
            target = item.location
            name = item.name
        } else if let item, item.depth > 0, let parent = item.location.parent {
            target = parent
            name = parent.lastComponent
        }
        guard let target else { return false }
        let sources = sources.uniqued().filter { $0 != target }
        guard !sources.isEmpty else { return false }
        browser.drop(sources, into: target, name: name)
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
    private var pathCache: [String: NSImage] = [:]

    /// Finder's icon for a folder or volume (drive icons, shared-folder badges).
    func icon(forPath path: String) -> NSImage {
        if let cached = pathCache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        pathCache[path] = image
        return image
    }

    func icon(for item: FileItem) -> NSImage {
        let key = item.isDirectory ? "/folder" : (item.name as NSString).pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let type = item.isDirectory ? UTType.folder : (UTType(filenameExtension: key) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }
}
