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
    /// The window's pane focus (two-pane layouts): binding the table to it lets
    /// the pane header and a right-click hand this list the keyboard.
    var paneFocus: FocusState<PaneFocus?>.Binding? = nil
    var paneTag: PaneFocus? = nil
    @State private var isTargeted = false
    /// The folder row a drag is over (it lights up and takes the drop).
    @State private var dropFolder: BrowseLocation?
    @FocusState private var tableFocused: Bool
    @AppStorage("showPathBar") private var showPathBar = true
    /// Column widths, order and visibility (right-click a column header), kept per window.
    @SceneStorage("fileColumns") private var columns = TableColumnCustomization<FileItem>()

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
        .sheet(isPresented: batchRenameShown) {
            if let items = browser.batchRenameItems { BatchRenameView(browser: browser, items: items) }
        }
        .sheet(isPresented: $browser.showGoToFolder) { GoToFolderView(browser: browser) }
    }

    private var batchRenameShown: Binding<Bool> {
        Binding(get: { browser.batchRenameItems != nil }, set: { if !$0 { browser.batchRenameItems = nil } })
    }

    /// Copy To ▸ and Move To ▸: the sidebar's favorites (NAS folders first) and
    /// Other Folder…, for archiving reviewed items without dragging.
    @ViewBuilder private func sendMenus(_ items: [FileItem]) -> some View {
        let parents = Set(items.compactMap(\.location.parent))
        let places = BrowserModel.destinations().filter { !parents.contains($0.location) }
        ForEach([false, true], id: \.self) { move in
            Menu(move ? "Move To" : "Copy To") {
                ForEach(places, id: \.location) { place in
                    Button(place.detail.map { "\(place.name) — \($0)" } ?? place.name) {
                        browser.send(items, to: place.location, name: place.name, move: move)
                    }
                }
                if !places.isEmpty { Divider() }
                Button("Other Folder…") { browser.sendToChosenFolder(items, move: move) }
            }
            .help(move ? "Each file is removed from here once its copy is verified by SHA-256" : "A verified copy")
        }
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
                .overlay {
                    // A search with nothing to show says so, instead of an empty list.
                    let query = browser.searchText.trimmingCharacters(in: .whitespaces)
                    if !query.isEmpty, browser.rows.isEmpty, !browser.items.isEmpty {
                        ContentUnavailableView.search(text: query)
                    }
                }
                .onChange(of: browser.selection) {
                    // Keep the file Quick Look is showing in view as ↑/↓ move
                    // through the list. A tick later: the selection change can
                    // come from the table's own delegate, and scrolling it from
                    // inside that update re-enters the table.
                    guard browser.previewURL != nil, let first = browser.selectedItems.first else { return }
                    Task { proxy.scrollTo(first.id) }
                }
        }
        // SwiftUI's Table shows no menu for right-clicks below the last row;
        // EmptySpaceMenu handles those (New Folder, Paste, Refresh).
        .background {
            ViewAnchor { view in
                EmptySpaceMenu.register(view, browser: browser)
                ClickToRename.install()
            }
                .allowsHitTesting(false)
        }
    }

    private var tableContent: some View {
        Table(of: FileItem.self, selection: $browser.selection, sortOrder: $browser.sortOrder,
              columnCustomization: $columns) {
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
                .frame(maxWidth: .infinity, alignment: .leading)
                // The folder a drag will drop into, as in the sidebar.
                .background {
                    if dropFolder == item.location {
                        RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.22)).padding(-2)
                    }
                }
                .overlay {
                    if dropFolder == item.location {
                        PixelMarchingAnts(cell: 1.5).padding(.horizontal, -1)
                    }
                }
            }
            .width(min: 180, ideal: 360)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Date Modified", value: \.modified) { item in
                Text(item.modified, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 160)
            .customizationID("modified")

            TableColumn("Size", value: \.size) { item in
                Text(item.isDirectory ? "—" : item.size.formatted(.byteCount(style: .file)))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 80)
            .customizationID("size")

            // Where the row stands in a transfer in the strip (PRD R2.6).
            TableColumn("Status") { item in
                StatusCell(status: browser.operations.transfers.status(for: item))
            }
            .width(min: 70, ideal: 110)
            .customizationID("status")

            TableColumn("Kind", value: \.kind) { item in
                Text(item.kind).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(min: 80, ideal: 140)
            .customizationID("kind")
        } rows: {
            ForEach(browser.rows) { item in
                TableRow(item)
                    .draggable(payload(for: item))
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        // Every drop is resolved here, from the row under the pointer. SwiftUI's
        // per-row targets didn't engage for drags that started in this list, so
        // folders never lit up and the drop landed in this folder instead.
        .onDrop(of: [.blitLocations, .fileURL], delegate: ListDropDelegate(
            itemUnderPointer: { itemUnderPointer() },
            selection: browser.selection,
            onTarget: { folder, targeted in
                if dropFolder != folder { dropFolder = folder }
                if isTargeted != targeted { isTargeted = targeted }
            },
            onDrop: { providers, item, copy in
                perform(providers, onto: item, copy: copy)
                // A drag update can still arrive after the drop and light the
                // folder again: clear once more when the drag has settled.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    dropFolder = nil
                    isTargeted = false
                }
            }))
        .overlay {
            // The whole list outlines only when the drop goes into this folder.
            if isTargeted, dropFolder == nil {
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
        .modifier(PaneFocusing(binding: paneFocus, tag: paneTag))
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
            let allLocal = !urls.isEmpty && urls.count == items.count
            if items.count == 1, items[0].isDirectory {
                Button("Open") { browser.open(items[0].location) }   // browses into it here
            } else if allLocal, !items.contains(where: \.isDirectory) {
                Button("Open") { for url in urls { NSWorkspace.shared.open(url) } }   // each in its default app
            }
            if allLocal {
                OpenWithMenu(urls: urls) { browser.report($0, action: "OPEN") }
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
            // In its own section, after the item's details and before the edits.
            Divider()
            Button(browser.deleteTitle(for: items), role: .destructive) { browser.requestDelete(items) }
            Divider()
            Button("New Folder") { browser.newFolder() }
            Button(items.count == 1 ? "Rename" : "Rename \(items.count) Items…") { browser.beginRename(items) }
            sendMenus(items)
            if urls.count == items.count {
                Button("Duplicate") { browser.duplicate(items) }
            }
            Divider()
            Button("Cut") { browser.copy(items, cut: true) }
            Button("Copy") { browser.copy(items, cut: false) }
            Button("Paste") { browser.paste(move: false) }
                .disabled(!browser.operations.canPaste)
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

    /// The row under the pointer, during a drag.
    private func itemUnderPointer() -> FileItem? {
        guard let row = EmptySpaceMenu.rowUnderPointer(in: browser), browser.rows.indices.contains(row) else { return nil }
        return browser.rows[row]
    }

    /// Reads what was dropped, then drops it onto `item` (nil: this folder).
    /// `copy` is ⌥ as it was at the drop.
    private func perform(_ providers: [NSItemProvider], onto item: FileItem?, copy: Bool) {
        Task {
            #if DEBUG
            let started = Date()
            #endif
            let sources = await Self.locations(from: providers)
            let accepted = drop(sources, onto: item, copy: copy)
            #if DEBUG
            UITestHarness.lastDrop = "\(providers.count) providers · \(sources.uniqued().count) sources · read in \(Int(Date().timeIntervalSince(started) * 1000)) ms · onto \(item?.name ?? "the list") · accepted \(accepted)"
            #endif
        }
    }

    /// Everything dragged, read from all the items at once. A multi-row drag
    /// makes one item per row, each carrying the whole selection, and some of
    /// them never answer a read: waiting on them one by one hung the drop. So
    /// every read starts together, and whatever has arrived when they've all
    /// answered, or after 3 s, is used.
    private static func locations(from providers: [NSItemProvider]) async -> [BrowseLocation] {
        guard !providers.isEmpty else { return [] }
        let found = await withCheckedContinuation { (continuation: CheckedContinuation<[BrowseLocation], Never>) in
            let gather = DropGather(expected: providers.count, continuation: continuation)
            for provider in providers { read(provider) { gather.add($0) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { gather.finish() }
        }
        return found.uniqued()
    }

    /// Reads one dragged item: Blit's own payload, or a file URL from Finder.
    private static func read(_ provider: NSItemProvider, _ done: @escaping @Sendable ([BrowseLocation]) -> Void) {
        if provider.hasItemConformingToTypeIdentifier(UTType.blitLocations.identifier) {
            _ = provider.loadDataRepresentation(for: .blitLocations) { data, _ in
                let payload = data.flatMap { try? JSONDecoder().decode(TransferPayload.self, from: $0) }
                done(payload?.locations ?? [])
            }
        } else if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in done(url.map { [.local($0)] } ?? []) }
        } else {
            done([])
        }
    }

    /// Drops onto a folder row go into that folder; onto a file, into the folder
    /// it's in; anywhere else, into this one.
    private func drop(_ sources: [BrowseLocation], onto item: FileItem?, copy: Bool? = nil) -> Bool {
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
        browser.drop(sources, into: target, name: name, copy: copy)
        return true
    }

    /// Dragging a selected row drags the whole selection, in list order.
    private func payload(for item: FileItem) -> TransferPayload {
        let items = browser.selection.contains(item.id) ? browser.selectedItems : [item]
        return TransferPayload(locations: items.map(\.location), folders: items.filter(\.isDirectory).map(\.location),
                               primary: item.location)
    }
}

/// Collects the reads of a drop's items; answers once, when all have come in
/// or at the timeout.
private final class DropGather: @unchecked Sendable {
    private let lock = NSLock()
    private var locations: [BrowseLocation] = []
    private var answers = 0
    private let expected: Int
    private var continuation: CheckedContinuation<[BrowseLocation], Never>?

    init(expected: Int, continuation: CheckedContinuation<[BrowseLocation], Never>) {
        self.expected = expected
        self.continuation = continuation
    }

    func add(_ found: [BrowseLocation]) {
        lock.lock()
        locations += found
        answers += 1
        let complete = answers >= expected
        lock.unlock()
        if complete { finish() }
    }

    func finish() {
        lock.lock()
        let pending = continuation
        continuation = nil
        let result = locations
        lock.unlock()
        pending?.resume(returning: result)
    }
}

/// Drops on a file list: the folder row under the pointer lights up and takes
/// the drop; anywhere else, this folder does (a file in an expanded folder:
/// that folder).
private struct ListDropDelegate: DropDelegate {
    let itemUnderPointer: () -> FileItem?
    let selection: Set<FileItem.ID>
    let onTarget: (BrowseLocation?, Bool) -> Void
    let onDrop: ([NSItemProvider], FileItem?, Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        let ok = info.hasItemsConforming(to: [.blitLocations, .fileURL])
        #if DEBUG
        UITestHarness.dropTrail.append("validate \(ok)")
        #endif
        return ok
    }

    func dropEntered(info: DropInfo) {
        #if DEBUG
        UITestHarness.dropTrail.append("entered")
        #endif
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        #if DEBUG
        UITestHarness.dropTrail.append("updated")
        #endif
        update(info)
        return DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        #if DEBUG
        UITestHarness.dropTrail.append("exited")
        #endif
        onTarget(nil, false)
    }

    func performDrop(info: DropInfo) -> Bool {
        #if DEBUG
        UITestHarness.dropTrail.append("perform \(info.itemProviders(for: [.blitLocations, .fileURL]).count)")
        #endif
        let item = itemUnderPointer()
        let copy = NSEvent.modifierFlags.contains(.option)
        onTarget(nil, false)
        onDrop(info.itemProviders(for: [.blitLocations, .fileURL]), item, copy)
        return true
    }

    private func update(_ info: DropInfo) {
        // A folder being dragged from this list can't take itself.
        let dragged = info.hasItemsConforming(to: [.blitLocations])
        let folder = itemUnderPointer().flatMap { item in
            item.isDirectory && !(dragged && selection.contains(item.id)) ? item.location : nil
        }
        onTarget(folder, true)
    }
}

/// Ties a file list's keyboard focus to the window's pane bookkeeping, when
/// the list is one of two panes (single lists have no pane focus to bind).
private struct PaneFocusing: ViewModifier {
    let binding: FocusState<PaneFocus?>.Binding?
    let tag: PaneFocus?

    @ViewBuilder func body(content: Content) -> some View {
        if let binding, let tag {
            content.focused(binding, equals: tag)
        } else {
            content
        }
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

    /// The row of `browser`'s file list under the pointer (during a drag), or nil.
    static func rowUnderPointer(in browser: BrowserModel) -> Int? {
        guard let view = anchors.first(where: { $0.browser === browser })?.view, let window = view.window,
              let content = window.contentView else { return nil }
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        guard view.convert(view.bounds, to: nil).contains(point),
              let hit = content.hitTest(content.convert(point, from: nil)) else { return nil }
        var current: NSView? = hit
        while let view = current {
            let table = view as? NSTableView ?? (view as? NSScrollView)?.documentView as? NSTableView
            if let table {
                let row = table.row(at: table.convert(point, from: nil))
                return row >= 0 ? row : nil
            }
            current = view.superview
        }
        return nil
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
/// The name being edited: a native text field that scrolls within its own
/// width as the cursor moves (the SwiftUI field in a table cell didn't redraw
/// the part of a long name scrolled into view). Return saves, Escape cancels,
/// clicking away saves; the name without its extension starts selected.
private struct RenameField: NSViewRepresentable {
    let browser: BrowserModel
    let item: FileItem

    func makeCoordinator() -> Coordinator { Coordinator(browser: browser, item: item) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: item.name)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.maximumNumberOfLines = 1
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.begin(field, attempt: 0)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let browser: BrowserModel
        let item: FileItem
        private var finished = false

        init(browser: BrowserModel, item: FileItem) {
            self.browser = browser
            self.item = item
        }

        /// Takes the keyboard and selects the base name, once the field is in a window.
        func begin(_ field: NSTextField, attempt: Int) {
            Task { @MainActor [weak field] in
                try? await Task.sleep(for: .milliseconds(attempt == 0 ? 0 : 50))
                do {
                    guard let field else { return }
                    guard let window = field.window else {
                        if attempt < 20 { self.begin(field, attempt: attempt + 1) }
                        return
                    }
                    window.makeFirstResponder(field)
                    let name = self.item.name as NSString
                    let ext = name.pathExtension
                    let length = self.item.isDirectory || ext.isEmpty || ext.contains(" ")
                        ? name.length : name.length - (ext as NSString).length - 1
                    field.currentEditor()?.selectedRange = NSRange(location: 0, length: max(0, length))
                }
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.cancelOperation(_:)) {
                finished = true
                browser.cancelRename()
                return true
            }
            if selector == #selector(NSResponder.insertNewline(_:)) {
                finish(control.stringValue)
                return true
            }
            return false
        }

        /// Clicking elsewhere (or Tab) ends editing: save, as Finder does.
        func controlTextDidEndEditing(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            finish(field.stringValue)
        }

        private func finish(_ text: String) {
            guard !finished else { return }
            finished = true
            browser.commitRename(item, to: text)
        }
    }
}

/// A Status cell: glyph plus word, never color alone (red only for failures).
private struct StatusCell: View {
    let status: FileStatus?

    var body: some View {
        if let status {
            HStack(spacing: 4) {
                if let glyph = status.glyph {
                    if let pixel = PixelGlyph(rawValue: glyph) {
                        Image(nsImage: pixel.image(size: 9))
                    } else {
                        Text(String(glyph))
                    }
                }
                Text(status.text).monospacedDigit().lineLimit(1)
            }
            .foregroundStyle(status.isFailure ? Color.failureText : .secondary)
            .help(status.help)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Status: \(status.text)")
        }
    }
}
