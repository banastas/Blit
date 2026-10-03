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
    /// This pane's columns (widths, order); which are shown comes from
    /// ColumnSettings, shared with the other pane and View › Columns.
    @State private var columns = TableColumnCustomization<FileItem>()
    /// Size stepped out because this pane is too narrow (not the user's choice:
    /// never saved, never shared with the other pane).
    @State private var sizeSqueezed = false
    /// Where a drag over this list would drop (the folder row lights up, or the
    /// whole list outlines). An object of its own, read only by the outline and
    /// the rows' marks: as state of this view, every change rebuilt the list and
    /// its drop handler mid-drag, and a quick drop let go just then was lost and
    /// left the drag stuck (the window took no clicks until force quit).
    @State private var dropHighlight = DragHover<ListDrop>()
    @FocusState private var tableFocused: Bool
    @AppStorage("showPathBar") private var showPathBar = true
    /// The path bar's height, kept clear under the AppKit list's rows.
    @State private var pathBarHeight: CGFloat = 24
    @AppStorage("showIconPreviews") private var showIconPreviews = true
    /// Column widths, order and visibility (right-click a column header), kept per window.

    var body: some View {
        #if DEBUG
        let _ = UITestHarness.tick("FileListView")
        #endif
        Group {
            if FileListFlags.native {
                nativeList
            } else {
                swiftUIList
            }
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

    /// The SwiftUI Table, with the states shown instead of it.
    private var swiftUIList: some View {
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
    }

    /// The AppKit list (-BlitNativeList YES): always there (hidden under an
    /// error or with no folder, so the next tab finds it), with the states
    /// over it and the path bar over its last rows.
    private var nativeList: some View {
        NativeFileList(browser: browser, isShown: browser.error == nil && browser.current != nil,
                       bottomInset: showPathBar && browser.current != nil ? pathBarHeight : 0,
                       iconPreviews: showIconPreviews)
            .overlay { nativeStates.allowsHitTesting(false) }
            .overlay(alignment: .bottom) {
                if showPathBar, browser.current != nil {
                    PathBar(browser: browser)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { _, height in pathBarHeight = height }
                }
            }
            .quickLookPreview($browser.previewURL, in: browser.previewURLs)
            .onChange(of: browser.selection) {
                // Like Finder: while Quick Look is open, it follows the selection.
                if browser.previewURL != nil { browser.previewSelection() }
            }
            .onAppear {
                // The second pane appearing: the two start at the same width.
                guard paneTag == .second else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if let list = FileListRegistry.scrollView(for: browser) { ColumnFit.centreDivider(from: list) }
                }
            }
    }

    @ViewBuilder private var nativeStates: some View {
        if let error = browser.error {
            ContentUnavailableView("Can't Open Folder", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if browser.current == nil {
            ContentUnavailableView("Choose a Location", systemImage: "sidebar.left")
        } else if browser.isLoading, browser.items.isEmpty {
            PixelSpinner(cell: 3)
        } else if browser.items.isEmpty {
            Text("Empty Folder").foregroundStyle(.tertiary)
        } else if !browser.searchText.trimmingCharacters(in: .whitespaces).isEmpty, browser.rows.isEmpty {
            ContentUnavailableView.search(text: browser.searchText.trimmingCharacters(in: .whitespaces))
        }
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
        // Shown / hidden columns follow the shared settings; hiding one from a
        // header's right-click menu updates them for both panes.
        .onAppear {
            applyColumnVisibility()
            // The second pane appearing: start the two at the same width.
            if paneTag == .second {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    if let anchor = EmptySpaceMenu.anchorView(for: browser) { FitColumns.centreDivider(near: anchor) }
                }
            }
        }
        .onChange(of: ColumnSettings.shared.hidden) { applyColumnVisibility() }
        .onChange(of: sizeSqueezed) { applyColumnVisibility() }
        .onChange(of: columns) {
            for column in ColumnSettings.optional where !(column.id == "size" && sizeSqueezed) {
                let shown = columns[visibility: column.id] != .hidden
                if shown != ColumnSettings.shared.isShown(column.id) { ColumnSettings.shared.set(column.id, shown: shown) }
            }
        }
        // Fit the columns to the pane, whenever the pane changes size.
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { _, _ in
            DispatchQueue.main.async { fitColumns() }
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
                                // One line, always: long release names lose their middle,
                                // keeping the end (year, group, extension) in view.
                                Text(item.name).lineLimit(1).truncationMode(.middle)
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
                                    .help(browser.partialSummary(partial))
                                    .accessibilityLabel("Partial download")
                            }
                            // With the Status column hidden (the default), the status is a
                            // small tag after the name, there only while it has something to say.
                            if browser.renaming != item.location, !ColumnSettings.shared.isShown("status"),
                               let status = browser.operations.transfers.status(for: item) {
                                StatusCell(status: status)
                                    .font(.caption)
                                    .fixedSize()
                            }
                        }
                    } icon: {
                        FileIcon(item: item)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                // The folder a drag will drop into, as in the sidebar.
                .background { DropFolderMark(highlight: dropHighlight, location: item.location, part: .fill) }
                .overlay { DropFolderMark(highlight: dropHighlight, location: item.location, part: .outline) }
            }
            .width(min: 110, ideal: 280)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("Modified", value: \.modified) { item in
                AdaptiveDate(date: item.modified)
            }
            .width(min: 64, ideal: 132)
            .customizationID("modified")

            TableColumn("Size", value: \.size) { item in
                Text(item.isDirectory ? "—" : item.size.formatted(.byteCount(style: .file)))
                    .lineLimit(1)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 54, ideal: 70)
            .customizationID("size")

            // Where the row stands in a transfer in the strip (PRD R2.6).
            TableColumn("Status") { item in
                StatusCell(status: browser.operations.transfers.status(for: item))
            }
            .width(min: 70, ideal: 110)
            .customizationID("status")

            TableColumn("Kind", value: \.kind) { item in
                Text(item.kind).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            }
            .width(min: 70, ideal: 120)
            .customizationID("kind")
        } rows: {
            ForEach(browser.rows) { item in
                TableRow(item)
                    .itemProvider { dragProvider(for: item) }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        // Every drop is resolved here, from the row under the pointer. SwiftUI's
        // per-row targets didn't engage for drags that started in this list, so
        // folders never lit up and the drop landed in this folder instead.
        .onDrop(of: [.blitLocations, .fileURL], delegate: ListDropDelegate(
            itemUnderPointer: { itemUnderPointer() },
            selection: browser.selection,
            highlight: dropHighlight,
            onDrop: { providers, item, copy in perform(providers, onto: item, copy: copy) }))
        .overlay {
            // The whole list outlines only when the drop goes into this folder.
            DropListOutline(highlight: dropHighlight)
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
            // The other pane of a two-pane window (F5 / F6 from the keyboard).
            if let other = BrowserModel.oppositePane?(browser), let there = other.current, there != browser.current {
                Button("Copy to “\(other.title)”") { browser.send(items, to: there, name: other.title, move: false) }
                Button("Move to “\(other.title)”") { browser.send(items, to: there, name: other.title, move: true) }
                if items.count == 1, items[0].isDirectory {
                    Button("Open in Other Pane") { other.open(items[0].location) }
                }
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

    private func applyColumnVisibility() {
        for column in ColumnSettings.optional {
            let shown = ColumnSettings.shared.isShown(column.id) && !(column.id == "size" && sizeSqueezed)
            let wanted: Visibility = shown ? .visible : .hidden
            if (columns[visibility: column.id] == .hidden) != (wanted == .hidden) { columns[visibility: column.id] = wanted }
        }
        DispatchQueue.main.async { fitColumns() }
    }

    private func fitColumns() {
        FitColumns.apply(for: browser) { squeezed in
            if sizeSqueezed != squeezed { sizeSqueezed = squeezed }
        }
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
            let sources = await DropReader.locations(from: providers)
            let accepted = drop(sources, onto: item, copy: copy)
            #if DEBUG
            UITestHarness.lastDrop = "\(providers.count) providers · \(sources.uniqued().count) sources · read in \(Int(Date().timeIntervalSince(started) * 1000)) ms · onto \(item?.name ?? "the list") · accepted \(accepted)"
            #endif
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

    /// What a dragged row carries, built by hand: SwiftUI's Transferable drag
    /// reached Finder and other apps as a file promise named after Blit's own
    /// type, so Finder saved a "Blit Locations" file instead of the file.
    /// A local row carries its file as a plain file URL (what Finder, Books and
    /// the Desktop take); every row carries Blit's payload, which Blit's own
    /// drop targets read first.
    private func dragProvider(for item: FileItem) -> NSItemProvider? {
        // Finder's rule: pressed off the name, the drag selects rows instead
        // (with no provider the table goes on selecting as the pointer moves).
        if RowDragRule.pressedOffName { return nil }
        #if DEBUG
        UITestHarness.dropTrail.append("provider for \(item.name) · grabbed \((RowDragRule.pressedItem(in: browser) ?? itemUnderPointer())?.name ?? "none") · selection \(browser.selectedItems.map(\.name)) · button down \(NSEvent.pressedMouseButtons & 1 == 1)")
        #endif
        // What's dragged, worked out without touching the selection (changing
        // it while the drag starts spoiled the drag for Finder): grabbing a row
        // that isn't selected drags just that row, as in Finder; otherwise the
        // selection goes. The table also asks for rows still selected from
        // before; those don't come along.
        let grabbed = RowDragRule.pressedItem(in: browser) ?? itemUnderPointer() ?? item
        let dragged = browser.selection.contains(grabbed.id) ? browser.selectedItems : [grabbed]
        // The table asks about the rows it thinks are dragged: the one under the
        // pointer when the drag began (a quick flick has already left the row
        // pressed for another) and any still selected. Each is answered with one
        // of the rows really dragged, the same one every time it's asked, and
        // any beyond them with nothing.
        guard let carried = RowDragRule.carried(for: item.id, from: dragged) else { return NSItemProvider() }
        let payload = TransferPayload(locations: dragged.map(\.location), folders: dragged.filter(\.isDirectory).map(\.location),
                                      primary: carried.location)
        DragContents.started(payload)   // runs when the drag begins
        let provider = NSItemProvider()
        if let url = carried.location.localURL {
            provider.registerObject(url as NSURL, visibility: .all)
            provider.suggestedName = url.lastPathComponent
        }
        if let data = try? JSONEncoder().encode(payload) {
            provider.registerDataRepresentation(for: .blitLocations, visibility: .all) { completion in
                completion(data, nil)
                return nil
            }
            // Server files have no file to hand over: the drag keeps only Blit's
            // payload, so other apps refuse it (SwiftUI's file promise for it
            // wrote a "Blit Locations" file into Finder).
            if payload.locations.allSatisfy({ $0.serverID != nil }) { DragContents.keepOnlyPayload(data) }
        }
        return provider
    }
}

/// The whole list's drop outline (a view of its own, so only it redraws).
private struct DropListOutline: View {
    let highlight: DragHover<ListDrop>

    var body: some View {
        if highlight.value == .list {
            PixelMarchingAnts(cell: 2).padding(3)
        }
    }
}

/// A folder row's drop mark: the fill behind it, or the marching outline.
private struct DropFolderMark: View {
    enum Part { case fill, outline }
    let highlight: DragHover<ListDrop>
    let location: BrowseLocation
    let part: Part

    var body: some View {
        if highlight.value == .folder(location) {
            switch part {
            case .fill: RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.22)).padding(-2)
            case .outline: PixelMarchingAnts(cell: 1.5).padding(.horizontal, -1)
            }
        }
    }
}

/// Drops on a file list: the folder row under the pointer lights up and takes
/// the drop; anywhere else, this folder does (a file in an expanded folder:
/// that folder).
private struct ListDropDelegate: DropDelegate {
    let itemUnderPointer: () -> FileItem?
    let selection: Set<FileItem.ID>
    let highlight: DragHover<ListDrop>
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
        highlight.entered(target(info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        #if DEBUG
        UITestHarness.dropTrail.append("updated")
        #endif
        highlight.moved(target(info))
        return DropProposal(operation: NSEvent.modifierFlags.contains(.option) ? .copy : .move)
    }

    func dropExited(info: DropInfo) {
        #if DEBUG
        UITestHarness.dropTrail.append("exited")
        #endif
        highlight.exited()
    }

    func performDrop(info: DropInfo) -> Bool {
        #if DEBUG
        UITestHarness.dropTrail.append("perform \(info.itemProviders(for: [.blitLocations, .fileURL]).count)")
        #endif
        let item = itemUnderPointer()
        let copy = NSEvent.modifierFlags.contains(.option)
        highlight.dropped()
        onDrop(info.itemProviders(for: [.blitLocations, .fileURL]), item, copy)
        return true
    }

    /// Where the drop would go: the folder row the drag is over, if it would
    /// take it (a folder being dragged from this list can't take itself), or
    /// the list's own folder.
    private func target(_ info: DropInfo) -> ListDrop {
        let dragged = info.hasItemsConforming(to: [.blitLocations])
        let folder = itemUnderPointer().flatMap { item in
            item.isDirectory && !(dragged && selection.contains(item.id)) ? item.location : nil
        }
        return folder.map(ListDrop.folder) ?? .list
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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            nonisolated(unsafe) let event = event
            return MainActor.assumeIsolated { handle(event) } ? nil : event
        }
    }

    /// The row of `browser`'s file list under the pointer (during a drag), or nil.
    static func rowUnderPointer(in browser: BrowserModel) -> Int? {
        guard let view = anchors.last(where: { $0.browser === browser && $0.view?.window != nil })?.view,
              let window = view.window, let content = window.contentView else { return nil }
        let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        // The list by position, as for right-clicks: while the HUD is open (a
        // transfer running), a hit test there finds the window's whole column
        // instead of the table, and no folder lit up under a drag.
        guard view.convert(view.bounds, to: nil).contains(point), let table = table(at: point, in: content) else { return nil }
        let row = table.row(at: table.convert(point, from: nil))
        return row >= 0 ? row : nil
    }

    #if DEBUG
    /// The views registered for `browser`'s list, in order: in a window or not, and where.
    static func debugAnchors(for browser: BrowserModel) -> String {
        anchors.filter { $0.browser === browser }.map { anchor in
            guard let view = anchor.view else { return "gone" }
            guard view.window != nil else { return "out of window" }
            let frame = view.convert(view.bounds, to: nil)
            return "in window \(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))×\(Int(frame.height))"
        }.joined(separator: " · ")
    }
    #endif

    /// The view covering `browser`'s file list.
    static func anchorView(for browser: BrowserModel) -> NSView? {
        anchors.last(where: { $0.browser === browser && $0.view?.window != nil })?.view
    }

    /// The browser whose file list covers `point` in `window`.
    static func browser(at point: NSPoint, in window: NSWindow) -> BrowserModel? {
        anchors.first(where: { anchor in
            guard let view = anchor.view, view.window === window else { return false }
            return view.convert(view.bounds, to: nil).contains(point)
        })?.browser
    }

    /// The file list (a table with column headers; the sidebar has none) whose
    /// scroll view covers `point` in window coordinates.
    private static func table(at point: NSPoint, in content: NSView) -> NSTableView? {
        var found: NSTableView?
        func search(_ view: NSView) {
            guard found == nil else { return }
            if let table = view as? NSTableView, table.headerView != nil, let scroll = table.enclosingScrollView,
               scroll.convert(scroll.bounds, to: nil).contains(point) {
                found = table
                return
            }
            view.subviews.forEach(search)
        }
        search(content)
        return found
    }

    private static func handle(_ event: NSEvent) -> Bool {
        // Right-clicks, and ⌃-clicks (the same menu everywhere else in macOS).
        // A plain click only sets up Finder's rule for a drag that may follow.
        if event.type == .leftMouseDown, !event.modifierFlags.contains(.control) {
            if let window = event.window, let content = window.contentView, let table = table(at: event.locationInWindow, in: content) {
                RowDragRule.prepare(for: event.locationInWindow, in: table, browser: browser(at: event.locationInWindow, in: window))
            } else {
                RowDragRule.prepare(for: .zero, in: nil, browser: nil)
            }
            return false
        }
        guard let window = event.window, let content = window.contentView else { return false }
        let point = event.locationInWindow
        guard let browser = browser(at: point, in: window) else { return false }
        // A right-click in a pane makes it the active one, as a left click does:
        // menu commands and ⌘⌫ must act on the pane the user is looking at.
        BrowserModel.onInteraction?(browser)
        // The pane's list is found from where the click is, not from the view
        // on top there: the walk up from the hit view gave up (no menu at all)
        // whenever something other than the table was on top.
        guard browser.current != nil, let table = table(at: point, in: content),
              let scroll = table.enclosingScrollView else { return false }
        // Column headers keep their own menu, and the path bar (over the list's
        // bottom inset) its own clicks; rows get the table's file menu.
        var list = scroll.convert(scroll.bounds, to: nil)
        list.origin.y += scroll.contentInsets.bottom
        list.size.height -= scroll.contentInsets.bottom + scroll.contentInsets.top
        if let header = table.headerView, header.convert(header.bounds, to: nil).contains(point) { return false }
        guard list.contains(point), table.row(at: table.convert(point, from: nil)) < 0 else { return false }

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

/// Finder's rule for a drag that starts on a row: from the file's icon or
/// name it moves the files; from the rest of the row (the blank part of the
/// Name column, the date, the size) it selects rows as it goes. Each press
/// records which it was; the rows' drag provider reads it when a drag starts.
/// (AppKit's verticalMotionCanBeginDrag has no effect on SwiftUI's table.)
@MainActor
enum RowDragRule {
    static private(set) var pressedOffName = false
    /// The row pressed, and in which list: a drag takes it, not the row under
    /// the pointer once the drag has begun (a quick flick is rows further on
    /// by then, and dragged the wrong file or folder).
    static private(set) var pressed: (browser: ObjectIdentifier, item: FileItem.ID)?

    static func prepare(for point: NSPoint, in table: NSTableView?, browser: BrowserModel?) {
        answers = [:]
        guard let table else { pressedOffName = false; pressed = nil; return }
        let local = table.convert(point, from: nil)
        let row = table.row(at: local)
        pressedOffName = row >= 0 && !isOnName(local, in: table, browser: browser)
        if let browser, browser.rows.indices.contains(row) {
            pressed = (ObjectIdentifier(browser), browser.rows[row].id)
        } else {
            pressed = nil
        }
    }

    /// Which dragged row each row the table asks about hands over (reset by
    /// each press).
    static private var answers: [FileItem.ID: FileItem.ID] = [:]

    /// The dragged row that `requested` hands over: itself when it's one of
    /// them, otherwise the first not yet handed over; nil when all have been.
    static func carried(for requested: FileItem.ID, from dragged: [FileItem]) -> FileItem? {
        if let answer = answers[requested] { return dragged.first { $0.id == answer } }
        let taken = Set(answers.values)
        let choice = dragged.first(where: { $0.id == requested && !taken.contains($0.id) })
            ?? dragged.first(where: { !taken.contains($0.id) })
        if let choice { answers[requested] = choice.id }
        return choice
    }

    /// The row pressed in `browser`'s list, if the last press was there.
    static func pressedItem(in browser: BrowserModel) -> FileItem? {
        guard let pressed, pressed.browser == ObjectIdentifier(browser) else { return nil }
        return browser.rows.first { $0.id == pressed.item }
    }

    /// Whether `local` (table coordinates) is on a row's icon or name. The
    /// Name cell lays out, left to right: the indent for its depth, the
    /// disclosure triangle (12), the icon (16) and the name, with the tags
    /// after it; the name's width is measured in the list's font.
    static func isOnName(_ local: NSPoint, in table: NSTableView, browser: BrowserModel?) -> Bool {
        let row = table.row(at: local)
        guard row >= 0, let column = table.tableColumns.firstIndex(where: { $0.title == "Name" }) else { return false }
        let cellRect = table.frameOfCell(atColumn: column, row: row)
        guard cellRect.minX <= local.x, local.x <= cellRect.maxX else { return false }
        guard let rows = browser?.rows, rows.indices.contains(row) else { return true }
        let item = rows[row]
        let indent = item.depth > 0 ? CGFloat(item.depth) * 16 + 4 : 0
        let iconEnd = cellRect.minX + indent + 12 + 4 + 16
        let nameWidth = (item.name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
        // The label's gap before the name, the name (cut to the cell), and room
        // for the tags that follow it (verified, partial, status).
        let nameEnd = min(cellRect.maxX, iconEnd + 6 + nameWidth + 18)
        return local.x <= nameEnd
    }
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

    /// Again on updates: a list shown for another tab is the same view with
    /// another browser, which has to be registered for it.
    func updateNSView(_ view: NSView, context: Context) {
        onView(view)
    }
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
/// A narrow pane squeezes the Name column first (down to its minimum), so
/// the other columns keep their width and everything fits without scrolling
/// sideways; the date then picks a shorter form. (By default the table kept
/// every column at its ideal width and scrolled.)
@MainActor
enum FitColumns {
    /// Fits `browser`'s list to its pane (on appearing and whenever the pane
    /// changes size). `squeeze` hides or shows Size when the pane is too
    /// narrow for it (through SwiftUI, which owns the table's columns).
    static func apply(for browser: BrowserModel, squeeze: @escaping (Bool) -> Void) {
        guard let anchor = EmptySpaceMenu.anchorView(for: browser) else { return }
        apply(near: anchor, squeeze: squeeze)
    }

    private static var squeezeHandlers: [ObjectIdentifier: (Bool) -> Void] = [:]

    static func apply(near anchor: NSView, squeeze: @escaping (Bool) -> Void) {
        // The anchor covers this list: its table is the one under the anchor's
        // centre (with two panes the window holds two).
        guard let window = anchor.window, let content = window.contentView else { return }
        let frame = anchor.convert(anchor.bounds, to: nil)
        let centre = NSPoint(x: frame.midX, y: frame.midY)
        var tables: [NSTableView] = []
        collect(content, into: &tables)
        guard let table = tables.first(where: { ($0.enclosingScrollView ?? $0).convert(($0.enclosingScrollView ?? $0).bounds, to: nil).contains(centre) })
        else { return }
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        squeezeHandlers[ObjectIdentifier(table)] = squeeze
        watch(table)
        // Asked for (a pane appearing or resizing, a column shown or hidden):
        // fit even at the same width.
        fittedWidth[ObjectIdentifier(table)] = nil
        scheduleFit(table)
    }

    /// Fits run after the current layout pass, never inside one: changing
    /// columns while AppKit lays the window out raised an exception (Blit
    /// crashed when a pane got narrow enough for Size to step out). Several
    /// requests before then make one fit.
    private static var pending = Set<ObjectIdentifier>()

    private static func scheduleFit(_ table: NSTableView) {
        guard pending.insert(ObjectIdentifier(table)).inserted else { return }
        DispatchQueue.main.async { [weak table] in
            guard let table else { return }
            pending.remove(ObjectIdentifier(table))
            fit(table)
        }
    }

    /// Refits whenever the list's visible area changes size (a pane resized,
    /// the window resized, the sidebar shown or hidden).
    private static var watched = Set<ObjectIdentifier>()
    private static func watch(_ table: NSTableView) {
        guard let clip = table.enclosingScrollView?.contentView, watched.insert(ObjectIdentifier(table)).inserted else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip, queue: .main) { [weak table] _ in
            MainActor.assumeIsolated { if let table { scheduleFit(table) } }
        }
    }

    /// Every column but Name has a set width; Name takes the rest. Only if
    /// that would push Name under its minimum do the date, then the size, give
    /// up width (the date then shows a shorter form); if even that isn't
    /// enough, Size steps out until there's room again.
    private static let widths: [String: CGFloat] = ["Modified": 132, "Size": 70, "Status": 100, "Kind": 120]

    /// Columns hidden only because the pane is too narrow (not by the user),
    /// per table: they come back when there's room.
    private static var squeezedOut: [ObjectIdentifier: Set<String>] = [:]
    /// The width each table was last fitted to: only a change of width refits
    /// (a scroller appearing, or a height change, would otherwise loop).
    private static var fittedWidth: [ObjectIdentifier: CGFloat] = [:]
    private static var fitting = false

    private static func fit(_ table: NSTableView) {
        guard !fitting, let clip = table.enclosingScrollView?.contentView else { return }
        let key = ObjectIdentifier(table)
        // What the list can show, less the part the floating sidebar covers.
        let room = (clip.bounds.width - sidebarOverlap(table)).rounded()
        guard fittedWidth[key].map({ abs($0 - room) >= 1 }) ?? true else { return }
        fitting = true
        defer { fitting = false }
        fittedWidth[key] = room

        // Worked out from the width alone (no measuring the result), so the
        // same width always gives the same columns. The inset list style
        // adds margins at both ends, and a little room is left at the end
        // for the overlay scroller.
        let margins: CGFloat = (table.style == .inset ? 20 : 0) + 14
        func needed(_ columns: [NSTableColumn], _ width: (NSTableColumn) -> CGFloat) -> CGFloat {
            columns.reduce(CGFloat(0)) { $0 + width($1) + table.intercellSpacing.width } + margins
        }
        if let size = table.tableColumns.first(where: { $0.title == "Size" }) {
            let others = table.tableColumns.filter { !$0.isHidden && $0 !== size }
            let atMinimum = needed(others + [size]) { $0.minWidth }
            let squeezed = squeezedOut[key]?.contains("Size") == true
            // Out below the minimum; back only with some room to spare (no flapping).
            let wanted = squeezed ? room < atMinimum + 20 : (!size.isHidden && room < atMinimum)
            if wanted != squeezed {
                squeezedOut[key] = wanted ? ["Size"] : []
                let handler = squeezeHandlers[key]
                DispatchQueue.main.async { handler?(wanted) }   // SwiftUI changes the column; that refits
                return
            }
        }

        let columns = table.tableColumns.filter { !$0.isHidden }
        guard let name = columns.first else { return }
        var set: [ObjectIdentifier: CGFloat] = [:]
        for column in columns.dropFirst() { set[ObjectIdentifier(column)] = widths[column.title] ?? column.width }
        var total = needed(columns) { column in column === name ? name.minWidth : set[ObjectIdentifier(column)] ?? column.width }
        for title in ["Modified", "Size"] where total > room {
            guard let column = columns.first(where: { $0.title == title }), let current = set[ObjectIdentifier(column)] else { continue }
            let give = min(total - room, current - column.minWidth)
            if give > 0 {
                set[ObjectIdentifier(column)] = current - give
                total -= give
            }
        }
        for column in columns.dropFirst() {
            if let width = set[ObjectIdentifier(column)], abs(column.width - width) > 0.5 { column.width = width }
        }
        let others = columns.dropFirst().reduce(CGFloat(0)) { $0 + (set[ObjectIdentifier($1)] ?? $1.width) + table.intercellSpacing.width }
        let target = max(name.minWidth, room - margins - table.intercellSpacing.width - others)
        if abs(name.width - target) > 0.5 { name.width = target }
    }

    /// How much of the table's width the sidebar covers (0 when it's hidden or
    /// beside it rather than over it).
    private static func sidebarOverlap(_ table: NSTableView) -> CGFloat {
        guard let window = table.window, let content = window.contentView, let scroll = table.enclosingScrollView else { return 0 }
        var sidebar: NSView?
        func find(_ view: NSView) {
            if sidebar != nil { return }
            if let outline = view as? NSOutlineView, outline.headerView == nil { sidebar = outline.enclosingScrollView ?? outline; return }
            view.subviews.forEach(find)
        }
        find(content)
        guard let sidebar, !sidebar.isHiddenOrHasHiddenAncestor else { return 0 }
        let listFrame = scroll.convert(scroll.bounds, to: nil)
        let sideFrame = sidebar.convert(sidebar.bounds, to: nil)
        return max(0, min(listFrame.maxX, sideFrame.maxX) - max(listFrame.minX, sideFrame.minX))
    }

    /// Puts the divider between the two panes in the middle (once, when the
    /// second pane appears; after that it's where the user drags it).
    static func centreDivider(near anchor: NSView) {
        var view: NSView? = anchor
        while let current = view {
            if let split = current as? NSSplitView, split.isVertical, split.subviews.count == 2 {
                split.setPosition(split.bounds.width / 2, ofDividerAt: 0)
                return
            }
            view = current.superview
        }
    }

    private static func collect(_ view: NSView, into tables: inout [NSTableView]) {
        if let table = view as? NSTableView, table.headerView != nil { tables.append(table) }
        for sub in view.subviews { collect(sub, into: &tables) }
    }
}

/// A date that always fits its column on one line: the first of these that
/// fits wins, from "Sep 28, 2026 at 20:00" down to "Today 20:00", "Sep 18" or
/// "2025-11-16", and at the narrowest "9/18" or "2025".
struct AdaptiveDate: View {
    let date: Date

    var body: some View {
        let forms = DateForms.forms(date)
        ViewThatFits(in: .horizontal) {
            ForEach(0..<4, id: \.self) { level in
                ZStack(alignment: .leading) {
                    Text(DateForms.widest[level]).lineLimit(1).hidden()
                    Text(forms[level]).lineLimit(1)
                }
            }
        }
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .help(forms[0])
    }
}

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
