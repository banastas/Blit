// Finder-style file list: native Table with alternating rows, newest first by
// default, monospaced digits for sizes and dates (PRD R2.4–R2.6), with file
// management from the context menu and drag and drop (R2.12).

import BlitRemote
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct FileListView: View {
    @Bindable var browser: BrowserModel
    /// Called when this list gets the keyboard, so file commands act on it.
    var onFocus: (() -> Void)? = nil
    @State private var isTargeted = false
    @FocusState private var tableFocused: Bool
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
        .confirmationDialog(deleteTitle, isPresented: deleteShown, presenting: browser.deleteRequest) { items in
            Button("Delete", role: .destructive) { browser.confirmDelete(items) }
            Button("Cancel", role: .cancel) {}
        } message: { items in
            Text(items.contains(where: \.isDirectory)
                 ? "This can't be undone. Folders are deleted with everything in them."
                 : "This can't be undone.")
        }
        .sheet(item: $browser.infoItem) { item in InfoView(item: item, browser: browser) }
        .sheet(isPresented: $browser.showGoToFolder) { GoToFolderView(browser: browser) }
    }

    private var deleteShown: Binding<Bool> {
        Binding(get: { browser.deleteRequest != nil }, set: { if !$0 { browser.deleteRequest = nil } })
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
        // SwiftUI's Table shows no menu for right-clicks below the last row;
        // EmptySpaceMenu handles those (New Folder, Paste, Refresh).
        .background {
            ViewAnchor { EmptySpaceMenu.register($0, browser: browser) }
                .allowsHitTesting(false)
        }
    }

    private var tableContent: some View {
        Table(of: FileItem.self, selection: $browser.selection, sortOrder: $browser.sortOrder) {
            TableColumn("Name", value: \.name) { item in
                HStack(spacing: 4) {
                    if item.depth > 0 { Spacer().frame(width: CGFloat(item.depth) * 16) }
                    disclosure(for: item)
                    Label {
                        HStack(spacing: 5) {
                            if browser.renaming == item.location {
                                RenameField(browser: browser, item: item)
                            } else {
                                Text(item.name).lineLimit(1)
                            }
                            if browser.renaming != item.location, !item.isDirectory, let url = item.location.localURL,
                               let verified = VerifiedIndex.shared.entry(for: url, size: item.size) {
                                Image(nsImage: PixelGlyph.check.image(size: 9))
                                    .foregroundStyle(.secondary)
                                    .help(verified.summary)
                                    .accessibilityLabel("Verified")
                            }
                            if browser.renaming != item.location, let partial = item.partial {
                                Image(nsImage: PixelGlyph.partial.image(size: 9))
                                    .foregroundStyle(.secondary)
                                    .help(partialSummary(partial))
                                    .accessibilityLabel("Partial download")
                            }
                        }
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
            // Drops between rows and below the last one (row drops above take
            // the rows themselves): into the folder there, else this one.
            .onInsert(of: [.blitLocations, .fileURL]) { index, providers in
                insert(providers, at: index)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .dropDestination(for: TransferPayload.self) { payloads, _ in
            drop(payloads.flatMap(\.locations), onto: nil)
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted {
                PixelMarchingAnts(cell: 2).padding(3)
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
        .overlay(alignment: .topTrailing) {
            // With the path bar hidden, show loading in the list's corner instead.
            if !showPathBar {
                LoadingIndicator(browser: browser, floating: true)
                    .font(.system(size: 11))
                    .padding(.top, 30)
                    .padding(.trailing, 10)
                    .allowsHitTesting(false)
            }
        }
        .focused($tableFocused)
        .onChange(of: tableFocused) { _, focused in if focused { onFocus?() } }
        .onKeyPress(.rightArrow) { expandSelection(true) }
        .onKeyPress(.leftArrow) { expandSelection(false) }
        .overlay {
            if browser.isLoading, browser.items.isEmpty {
                PixelSpinner(cell: 3)
            } else if browser.items.isEmpty {
                Text("Empty Folder").foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder private func menu(for items: [FileItem]) -> some View {
        if items.isEmpty {
            Button("New Folder") { browser.newFolder() }
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
            if items.count == 1 {
                Button("Get Info") { browser.infoItem = items[0] }
            }
            if items.count == 1, items[0].partial != nil {
                Divider()
                let problem = browser.resumeProblem(items[0])
                Button("Resume Download") { browser.resumeDownload(items[0]) }
                    .disabled(problem != nil)
                    .help(problem ?? "Download the rest of this file into this folder.")
            }
            Divider()
            Button("New Folder") { browser.newFolder() }
            if items.count == 1 {
                Button("Rename") { browser.beginRename(items[0]) }
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

    private func partialSummary(_ partial: PartialDownload) -> String {
        let done = Int64(partial.done).formatted(.byteCount(style: .file))
        let total = Int64(partial.size).formatted(.byteCount(style: .file))
        let from = browser.server(for: partial)?.displayName ?? partial.source?.host ?? "a server"
        return "\(done) of \(total) downloaded from \(from): \(partial.remotePath). Right-click › Resume Download to finish it, or Move to Trash to discard it."
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
                        PixelSpinner(cell: 1.5)
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
        // While a name is being edited, arrows move the text cursor.
        guard browser.renaming == nil else { return .ignored }
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

    /// A drop between rows (`index` is the row below it) or below the last
    /// row: into the expanded folder it falls inside, else this folder.
    private func insert(_ providers: [NSItemProvider], at index: Int) {
        let rows = browser.rows
        var target = browser.current
        var name = browser.title
        if index < rows.count, rows[index].depth > 0, let parent = rows[index].location.parent {
            target = parent
            name = parent.lastComponent
        }
        guard let target else { return }
        let copy = NSEvent.modifierFlags.contains(.option)
        Task {
            var sources: [BrowseLocation] = []
            for provider in providers {
                sources += await Self.locations(from: provider)
            }
            sources = sources.uniqued().filter { $0 != target }
            if !sources.isEmpty { browser.drop(sources, into: target, name: name, copy: copy) }
        }
    }

    /// Locations in a dragged item: Blit's own payload, or a file URL from Finder.
    private static func locations(from provider: NSItemProvider) async -> [BrowseLocation] {
        if provider.hasItemConformingToTypeIdentifier(UTType.blitLocations.identifier) {
            return await withCheckedContinuation { continuation in
                _ = provider.loadDataRepresentation(for: .blitLocations) { data, _ in
                    let payload = data.flatMap { try? JSONDecoder().decode(TransferPayload.self, from: $0) }
                    continuation.resume(returning: payload?.locations ?? [])
                }
            }
        }
        guard provider.canLoadObject(ofClass: URL.self) else { return [] }
        return await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                continuation.resume(returning: url.map { [.local($0)] } ?? [])
            }
        }
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
        return TransferPayload(locations: items.map(\.location), folders: items.filter(\.isDirectory).map(\.location),
                               primary: item.location)
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

/// Right-clicks on empty space in a file list. SwiftUI's Table doesn't show
/// its context menu there, so Blit shows the folder menu itself, as Finder does.
@MainActor
enum EmptySpaceMenu {
    private final class Anchor {
        weak var view: NSView?
        weak var browser: BrowserModel?
    }
    private static var anchors: [Anchor] = []
    private static var monitor: Any?

    /// `view` covers a file list; right-clicks on its empty space act on `browser`.
    static func register(_ view: NSView, browser: BrowserModel) {
        anchors.removeAll { $0.view == nil || $0.view === view }
        let anchor = Anchor()
        anchor.view = view
        anchor.browser = browser
        anchors.append(anchor)
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { event in
            nonisolated(unsafe) let event = event
            return MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    /// The browser whose file list covers `point` in `window`.
    static func browser(at point: NSPoint, in window: NSWindow) -> BrowserModel? {
        anchors.first(where: { anchor in
            guard let view = anchor.view, view.window === window else { return false }
            return view.convert(view.bounds, to: nil).contains(point)
        })?.browser
    }

    private static func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, let content = window.contentView else { return false }
        // A right-click in a pane makes it the active one, as a left click does:
        // menu commands and ⌘⌫ must act on the pane the user is looking at.
        if let browser = browser(at: event.locationInWindow, in: window) { BrowserModel.onInteraction?(browser) }
        guard let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)) else { return false }
        var table: NSTableView?
        var view: NSView? = hit
        while let current = view {
            if current is NSTableHeaderView { return false }   // column headers keep their own behavior
            if let found = current as? NSTableView { table = found; break }
            if let scroll = current as? NSScrollView, let found = scroll.documentView as? NSTableView { table = found; break }
            view = current.superview
        }
        // Only file lists (they have column headers; the sidebar doesn't), and only below the rows.
        guard let table, table.headerView != nil,
              table.row(at: table.convert(event.locationInWindow, from: nil)) < 0 else { return false }
        guard let browser = anchors.first(where: { anchor in
            guard let view = anchor.view, view.window === window else { return false }
            return view.convert(view.bounds, to: nil).contains(event.locationInWindow)
        })?.browser, browser.current != nil else { return false }

        browser.selection = []
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ClosureMenuItem("New Folder") { browser.newFolder() })
        menu.addItem(.separator())
        let paste = ClosureMenuItem("Paste") { browser.paste(move: false) }
        paste.isEnabled = browser.operations.canPaste
        menu.addItem(paste)
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("Refresh") { browser.reload() })
        NSMenu.popUpContextMenu(menu, with: event, for: table)
        return true
    }
}

/// A menu item that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}

/// Hands over an invisible NSView that tracks a SwiftUI view's frame.
struct ViewAnchor: NSViewRepresentable {
    let onView: (NSView) -> Void

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        DispatchQueue.main.async { onView(view) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// Editing a name in place (PRD R2.12): the name without its extension starts
/// selected, as in Finder. Return saves, Esc cancels, clicking away saves.
private struct RenameField: View {
    let browser: BrowserModel
    let item: FileItem
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .focused($focused)
            .onAppear {
                text = item.name
                DispatchQueue.main.async {
                    focused = true
                    // Focusing selects everything; then narrow it to the name
                    // without its extension (the field editor is AppKit's). The
                    // editor can take a moment to appear, so try a few times.
                    for delay in [0.05, 0.15, 0.3, 0.5] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { selectBaseName() }
                    }
                }
            }
            .onSubmit { browser.commitRename(item, to: text) }
            .onExitCommand { browser.cancelRename() }
            .onChange(of: focused) { _, isFocused in
                if !isFocused { browser.commitRename(item, to: text) }
            }
    }

    private func selectBaseName() {
        let whole = (item.name as NSString).length
        // Only while everything is still selected: never undo the user's own cursor moves.
        // The field editor editing this name, in whichever window has it.
        let editor = NSApp.windows.lazy.compactMap { $0.firstResponder as? NSTextView }.first { $0.string == item.name }
        guard let editor, editor.selectedRange() == NSRange(location: 0, length: whole) else { return }
        let ext = (item.name as NSString).pathExtension
        let length = item.isDirectory || ext.isEmpty || ext.contains(" ")
            ? whole
            : whole - (ext as NSString).length - 1
        editor.setSelectedRange(NSRange(location: 0, length: max(0, length)))
    }
}
