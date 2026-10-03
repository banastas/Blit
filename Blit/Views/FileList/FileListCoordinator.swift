// The AppKit file list (PRD R2.4–R2.6), being built to replace the SwiftUI
// Table: one table per pane, shared by every tab (a tab switch swaps the
// model and fills the rows on screen again, building no views), kept in step
// with the pane's BrowserModel by observation tracking. The model is the
// source of truth: the table shows its rows, selection and sort, and hands
// the user's changes back.

import AppKit
import Observation
import UniformTypeIdentifiers

/// The rows on screen, for the decorations' watch (what to read).
@MainActor
@Observable
private final class Viewport {
    var rows: Range<Int> = 0..<0
}

/// What the list shows of a model, read in one pass.
private struct ListSnapshot: Equatable, Sendable {
    struct SortKey: Equatable, Sendable {
        var column: SortColumn
        var ascending: Bool
    }

    var folder: BrowseLocation?
    var rows: [FileItem]
    var selection: Set<BrowseLocation>
    var sort: SortKey?
    var hiddenColumns: Set<String>
    var expanded: Set<BrowseLocation>
    var renaming: BrowseLocation?

    @MainActor
    init(_ model: BrowserModel) {
        folder = model.current
        rows = model.rows
        expanded = model.expanded
        renaming = model.renaming
        selection = model.selection
        sort = model.sortOrder.first.flatMap { comparator in
            SortColumn(comparator).map { SortKey(column: $0, ascending: comparator.order == .forward) }
        }
        hiddenColumns = ColumnSettings.shared.hidden
    }
}

@MainActor
final class FileListCoordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let table = FileTableView()
    let scrollView = FileListScrollView()
    /// The pane shown now (another tab's pane after a switch).
    private(set) weak var model: BrowserModel?
    /// The rows shown, as of the last update: the table reads only these.
    private(set) var rows: [FileItem] = []
    private(set) var rowIndex: [BrowseLocation: Int] = [:]
    /// The folder the rows came from (a new one starts at the top).
    private var shownFolder: BrowseLocation?
    /// Counts the model's watches: a change the model reports for an older
    /// watch (another pane shown since) is ignored.
    private var watchGeneration = 0
    /// Set while the coordinator changes the table, so the table's own
    /// notifications (selection, sort) aren't taken for the user's.
    private var isApplying = false
    /// Which of DateForms' forms fits the Modified column.
    private var dateLevel = 1
    /// The width the columns were last fitted to, and whether Size had to step out.
    private var fittedRoom: CGFloat?
    private var sizeOut = false
    private var fitPending = false
    private var frameObserver: NSObjectProtocol?
    private var scrollObserver: NSObjectProtocol?
    /// Quick Look thumbnails for local files (View › Show Icon Previews).
    private var iconPreviews = true
    /// The expanded folders as of the last update (a change slides rows in or out).
    private var shownExpanded = Set<BrowseLocation>()
    private let viewport = Viewport()
    /// Renaming (FileListRename.swift): the field over the name, what it
    /// renames and in which pane, and whether it has been saved or cancelled.
    var renameField: NSTextField?
    var renamingItem: FileItem?
    weak var renamingModel: BrowserModel?
    var renameFinished = false
    /// Click to rename: the press on a row, and the rename waiting out the
    /// double-click interval.
    var press: ListPress?
    var pendingRename: Task<Void, Never>?
    /// The keyboard was asked for while the list couldn't take it (hidden for
    /// a pane with no folder yet, or not in the window yet).
    private var keyboardPending = false
    /// Drops (FileListDrag.swift): where the drag over the list would go, its
    /// watch, what the drag carries (read once per drag), and the list's
    /// outline for a drop into its own folder.
    let dropHover = DragHover<ListDrop>()
    var dropWatch: Task<Void, Never>?
    var dragged: (sequence: Int, locations: [BrowseLocation])?
    let listOutline = PixelAntsView(cell: 2)
    #if DEBUG
    /// The last press was on a row but off its icon and name, where a drag
    /// selects rows (the drag tests).
    var pressedOffName = false
    #endif
    /// Watches what the visible rows' marks are made of (status, ✓, the
    /// spinner), and refreshes them once a second while a transfer runs (its
    /// byte count isn't observed).
    private var decorations: Task<Void, Never>?
    private var ticker: Timer?

    override init() {
        super.init()
        setUp()
    }

    isolated deinit {
        for observer in [frameObserver, scrollObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
        decorations?.cancel()
        dropWatch?.cancel()
        ticker?.invalidate()
    }

    private func setUp() {
        table.coordinator = self
        table.style = .inset
        // The SwiftUI Table's measured rows: 24.5 pt tall, 17 pt between columns.
        table.rowHeight = 24.5
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = NSSize(width: 17, height: 0)
        table.usesAlternatingRowBackgroundColors = true
        table.backgroundColor = .controlBackgroundColor
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.allowsTypeSelect = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.floatsGroupRows = false
        for column in FileColumn.allCases {
            let tableColumn = NSTableColumn(identifier: column.identifier)
            tableColumn.title = column.title
            tableColumn.minWidth = column.minWidth
            tableColumn.width = column.idealWidth
            tableColumn.resizingMask = [.autoresizingMask, .userResizingMask]
            tableColumn.sortDescriptorPrototype = column.sortPrototype
            tableColumn.isHidden = column != .name && !ColumnSettings.shared.isShown(column.rawValue)
            table.addTableColumn(tableColumn)
        }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openClicked)
        table.registerForDraggedTypes([NSPasteboard.PasteboardType(UTType.blitLocations.identifier), .fileURL])
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.automaticallyAdjustsContentInsets = false
        if let modified = table.tableColumn(withIdentifier: FileColumn.modified.identifier) {
            dateLevel = DateForms.level(forWidth: modified.width - 4, font: CellFonts.digits)
        }
        // Refit whenever the list's visible width changes (a pane or the window
        // resized, the sidebar shown or hidden).
        let clip = scrollView.contentView
        clip.postsFrameChangedNotifications = true
        frameObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: clip,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.scheduleFit()
                self?.noteVisibleRows()
            }
        }
        // Scrolling changes which rows' marks are watched.
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.noteVisibleRows() }
        }
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        // To Finder and other apps: a copy, unless they ask otherwise (⌘ moves).
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        // Blit draws its own drop marks (FileRowView, the list's outline).
        table.draggingDestinationFeedbackStyle = .none
        listOutline.isHidden = true
        listOutline.autoresizingMask = [.width, .height]
        scrollView.addSubview(listOutline)
        watchDropHover()
        let header = NSMenu()
        header.delegate = self
        header.autoenablesItems = false
        table.headerView?.menu = header
        fillHeaderMenu(header)
        let context = NSMenu()
        context.autoenablesItems = false
        table.menu = context
    }

    // MARK: Fitting the columns

    /// Fits after the current layout pass, never inside one (changing columns
    /// while AppKit lays out the window raised an exception). Several requests
    /// before then make one fit.
    private func scheduleFit(force: Bool = false) {
        if force { fittedRoom = nil }
        guard !fitPending else { return }
        fitPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.fitPending = false
            self.fitColumns()
        }
    }

    private func fitColumns() {
        guard scrollView.window != nil else { return }
        let room = (scrollView.contentView.bounds.width - ColumnFit.sidebarOverlap(scrollView)).rounded()
        // Only a change of width refits (a scroller appearing, or a change of
        // height, would otherwise loop).
        if let fittedRoom, abs(fittedRoom - room) < 1 { return }
        fittedRoom = room
        let hidden = ColumnSettings.shared.hidden
        let shown = table.tableColumns.compactMap { FileColumn($0.identifier) }
            .filter { $0 == .name || !hidden.contains($0.rawValue) }
        let result = ColumnFit.fit(room: room, shown: shown, sizeOut: sizeOut, spacing: table.intercellSpacing.width,
                                   margins: (table.style == .inset ? 20 : 0) + 14)
        sizeOut = result.sizeOut
        // With autoresizing on, the first column grew back to fill the table's
        // old width (the table only shrinks to the pane once its columns fit).
        let autoresizing = table.columnAutoresizingStyle
        table.columnAutoresizingStyle = .noColumnAutoresizing
        for column in table.tableColumns {
            guard let id = FileColumn(column.identifier) else { continue }
            let hide = !shown.contains(id) || (id == .size && result.sizeOut)
            if column.isHidden != hide { column.isHidden = hide }
            if !hide, let width = result.widths[id], abs(column.width - width) > 0.5 { column.width = width }
        }
        table.tile()
        table.columnAutoresizingStyle = autoresizing
        if let modified = table.tableColumn(withIdentifier: FileColumn.modified.identifier) {
            let level = DateForms.level(forWidth: modified.width - 4, font: CellFonts.digits)
            if level != dateLevel {
                dateLevel = level
                refillVisibleRows()
            }
        }
    }

    // MARK: The SwiftUI side

    func update(browser: BrowserModel, isShown: Bool, bottomInset: CGFloat, iconPreviews: Bool) {
        setShown(isShown)
        if iconPreviews != self.iconPreviews {
            self.iconPreviews = iconPreviews
            refillVisibleRows()
        }
        if scrollView.contentInsets.bottom != bottomInset {
            scrollView.contentInsets.bottom = bottomInset
            scrollView.scrollerInsets.bottom = bottomInset
        }
        show(browser)
    }

    /// Hidden while the pane has no folder or can't open it (the wrapper's
    /// message shows instead). Hiding the list with the keyboard would hand it
    /// to the window's next key view, the toolbar's search field: the list
    /// keeps it waiting instead, and takes it back on showing unless something
    /// else took it meanwhile.
    private func setShown(_ shown: Bool) {
        guard scrollView.isHidden == shown else { return }
        let window = table.window
        if shown {
            scrollView.isHidden = false
            if keyboardPending, let window, window.firstResponder === window || window.firstResponder == nil {
                window.makeFirstResponder(table)
            }
            keyboardPending = false
        } else {
            if let window, window.firstResponder === table {
                keyboardPending = true
                window.makeFirstResponder(nil)
            }
            scrollView.isHidden = true
        }
    }

    /// The table went into a window (the first time it shows): it takes the
    /// keyboard if it was asked for before.
    func tableMovedToWindow() {
        guard keyboardPending, !scrollView.isHidden, let window = table.window else { return }
        keyboardPending = false
        if window.firstResponder === window || window.firstResponder == nil { window.makeFirstResponder(table) }
    }

    /// The list is going (its pane hidden, or its window closed: SwiftUI
    /// keeps a closed window's views, still watching their panes, so the table
    /// says when its window closes). A name being edited is saved.
    func detach() {
        guard let model else { return }
        if let field = renameField { controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field)) }
        watchGeneration += 1
        removeRenameField()
        cancelPendingRename()
        decorations?.cancel()
        decorations = nil
        ticker?.invalidate()
        ticker = nil
        dropHover.exited()
        model.listScrollOrigin = scrollView.contentView.bounds.origin
        if model.keyboardTarget === self { model.keyboardTarget = nil }
        FileListRegistry.unregister(self, for: model)
        self.model = nil
    }

    /// Shows `model`'s rows (another tab's pane, after a switch): all at once,
    /// in this update, with the selection, sort and scroll it had.
    private func show(_ model: BrowserModel) {
        guard model !== self.model else { return }
        if let old = self.model {
            // A name being edited is saved, in its own pane.
            if let field = renameField { controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field)) }
            cancelPendingRename()
            dropHover.exited()
            showDropMark()
            old.listScrollOrigin = scrollView.contentView.bounds.origin
            if old.keyboardTarget === self { old.keyboardTarget = nil }
            FileListRegistry.unregister(self, for: old)
        }
        self.model = model
        model.keyboardTarget = self
        FileListRegistry.register(self, for: model)
        let snapshot = watch(model)
        isApplying = true
        showColumns(hidden: snapshot.hiddenColumns)
        shownFolder = snapshot.folder
        shownExpanded = snapshot.expanded
        replaceRows(snapshot.rows)
        showSelection(snapshot.selection)
        showSort(snapshot.sort)
        isApplying = false
        scroll(to: model.listScrollOrigin)
        watchDecorations(of: model)
        showRenaming(snapshot.renaming)
        if model.wantsKeyboard {
            model.wantsKeyboard = false
            DispatchQueue.main.async { [weak self] in self?.takeKeyboardFocus() }
        }
    }

    /// Reads what the list shows of `model` and watches it for changes, in one
    /// pass (rows are sorted once). A change is applied a turn later, after the
    /// model has finished changing, and watched again from there.
    private func watch(_ model: BrowserModel) -> ListSnapshot {
        watchGeneration += 1
        let generation = watchGeneration
        return withObservationTracking {
            ListSnapshot(model)
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.watchGeneration == generation, self.model === model else { return }
                    self.apply(self.watch(model))
                }
            }
        }
    }

    private func apply(_ snapshot: ListSnapshot) {
        let applying = isApplying
        isApplying = true
        defer { isApplying = applying }
        showColumns(hidden: snapshot.hiddenColumns)
        let expandedChanged = snapshot.expanded != shownExpanded
        shownExpanded = snapshot.expanded
        if snapshot.folder != shownFolder {
            shownFolder = snapshot.folder
            replaceRows(snapshot.rows)
            scroll(to: nil)
        } else if snapshot.rows != rows {
            updateRows(snapshot.rows, sliding: expandedChanged)
        }
        let selectionChanged = IndexSet(snapshot.selection.compactMap { rowIndex[$0] }) != table.selectedRowIndexes
        showSelection(snapshot.selection)
        showSort(snapshot.sort)
        // While Quick Look follows the selection, the row it shows stays in view.
        if selectionChanged, model?.previewURL != nil, let first = table.selectedRowIndexes.first {
            table.scrollRowToVisible(first)
        }
        noteVisibleRows()
        showRenaming(snapshot.renaming)
    }

    /// Rows came or went in the same folder: slid in or out where a folder
    /// opened or closed, without moving the rest; anything bigger (a re-sort)
    /// is filled again in place.
    private func updateRows(_ new: [FileItem], sliding: Bool) {
        let old = rows
        let difference = new.map(\.id).difference(from: old.map(\.id))
        var removals = IndexSet()
        var insertions = IndexSet()
        var moved = false
        for change in difference {
            switch change {
            case .remove(let offset, _, let associated):
                removals.insert(offset)
                moved = moved || associated != nil
            case .insert(let offset, _, let associated):
                insertions.insert(offset)
                moved = moved || associated != nil
            }
        }
        guard !moved, removals.count + insertions.count <= 200, !(removals.isEmpty && insertions.isEmpty) else {
            replaceRows(new)
            return
        }
        setRows(new)
        table.beginUpdates()
        if !removals.isEmpty { table.removeRows(at: removals, withAnimation: sliding ? .slideUp : []) }
        if !insertions.isEmpty { table.insertRows(at: insertions, withAnimation: sliding ? .slideDown : []) }
        table.endUpdates()
        refillVisibleRows()
    }

    /// Shows other rows in the views already there: the row count changes and
    /// each visible cell is filled again (a reload would take every row's
    /// views out of the window and put new ones in).
    private func replaceRows(_ new: [FileItem]) {
        setRows(new)
        table.noteNumberOfRowsChanged()
        refillVisibleRows()
    }

    /// Fills every cell the table has on screen from the current rows.
    private func refillVisibleRows() {
        guard let model else { return }
        let context = cellContext(model)
        table.enumerateAvailableRowViews { rowView, row in
            guard self.rows.indices.contains(row) else { return }
            for column in 0..<rowView.numberOfColumns {
                guard let cell = rowView.view(atColumn: column) as? NSTableCellView else { continue }
                self.fill(cell, with: self.rows[row], context: context)
            }
        }
        if dropHover.value != nil { showDropMark() }
    }

    /// `new` is always the model's rows as just read, so its index is the
    /// model's (kept with them: a tab switch back reuses it).
    private func setRows(_ new: [FileItem]) {
        rows = new
        if let index = model?.rowIndex, index.count == new.count {
            rowIndex = index
        } else {
            rowIndex = Dictionary(new.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    private func showSelection(_ selection: Set<BrowseLocation>) {
        let wanted = IndexSet(selection.compactMap { rowIndex[$0] })
        guard wanted != table.selectedRowIndexes else { return }
        let applying = isApplying
        isApplying = true
        table.selectRowIndexes(wanted, byExtendingSelection: false)
        isApplying = applying
    }

    private func showSort(_ sort: ListSnapshot.SortKey?) {
        let descriptors = sort.flatMap { key in
            FileColumn(key.column).map { [NSSortDescriptor(key: $0.rawValue, ascending: key.ascending)] }
        } ?? []
        guard table.sortDescriptors != descriptors else { return }
        let applying = isApplying
        isApplying = true
        table.sortDescriptors = descriptors
        isApplying = applying
    }

    /// The user's shown columns changed (View › Columns, the header menu):
    /// fit them again (and the status moves between its column and the name).
    private var shownHidden: Set<String>?
    private func showColumns(hidden: Set<String>) {
        guard hidden != shownHidden else { return }
        let first = shownHidden == nil
        shownHidden = hidden
        scheduleFit(force: true)
        if let menu = table.headerView?.menu { fillHeaderMenu(menu) }
        if !first { refillVisibleRows() }
    }

    // MARK: The marks on visible rows

    /// Notes which rows are on screen (the decorations' watch reads them).
    private func noteVisibleRows() {
        let visible = table.rows(in: table.visibleRect)
        let range = visible.location..<(visible.location + visible.length)
        if viewport.rows != range { viewport.rows = range }
    }

    /// Refreshes the visible rows' marks when what they're made of changes:
    /// a transfer's statuses, Blit's verified files, a folder loading. Only the
    /// rows on screen are read; a scroll reads the new ones.
    private func watchDecorations(of model: BrowserModel) {
        decorations?.cancel()
        noteVisibleRows()
        let viewport = viewport
        let changes = Observations { [weak self] () -> Int in
            guard let self else { return 0 }
            var hasher = Hasher()
            hasher.combine(model.loadingChildren)
            let transfers = model.operations.transfers
            hasher.combine(transfers.jobs.contains(where: \.isActive))
            for row in viewport.rows where self.rows.indices.contains(row) {
                let item = self.rows[row]
                hasher.combine(transfers.status(for: item))
                if !item.isDirectory, let url = item.location.localURL {
                    hasher.combine(VerifiedIndex.shared.entry(for: url, size: item.size)?.summary)
                }
            }
            return hasher.finalize()
        }
        decorations = Task { [weak self] in
            for await _ in changes {
                guard let self, self.model === model else { return }
                self.refillVisibleRows()
                self.tickWhileTransferring(model)
            }
        }
    }

    /// A transfer's byte count isn't observed (it changes too often): while
    /// one runs, the visible rows' marks are refreshed once a second.
    private func tickWhileTransferring(_ model: BrowserModel) {
        let running = model.operations.transfers.jobs.contains(where: \.isActive)
        if running, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refillVisibleRows() }
            }
        } else if !running {
            ticker?.invalidate()
            ticker = nil
        }
    }

    // MARK: Keys and the keyboard

    /// Return with several rows selected (one is renamed, by the app's key
    /// handling): opens the first, as a double-click would.
    func openSelection() -> Bool {
        guard let model, let item = model.selectedItems.first else { return false }
        open(item, in: model)
        return true
    }

    /// Tab and ⇧Tab: the keyboard goes to the other pane.
    func focusOtherPane() -> Bool {
        guard let model, let other = BrowserModel.oppositePane?(model) else { return false }
        other.requestKeyboardFocus()
        BrowserModel.onInteraction?(other)
        return true
    }

    /// A click or right-click in the list: its pane becomes the active one at
    /// once (SwiftUI's gestures never see the clicks the table takes).
    func noteInteraction() {
        if let model { BrowserModel.onInteraction?(model) }
    }

    /// → opens the selected folders in place; ← closes them, or from a row
    /// inside one, closes it and selects it. While a name is edited the arrows
    /// move the text cursor.
    func expandSelection(_ open: Bool) -> Bool {
        guard let model, model.renaming == nil else { return false }
        let selected = model.selectedItems
        guard !selected.isEmpty else { return false }
        for item in selected {
            if item.isDirectory, open || model.expanded.contains(item.location) {
                model.setExpanded(item.location, open)
            } else if !open, item.depth > 0, let parent = item.location.parent {
                model.setExpanded(parent, false)
                model.selection = [parent]
            }
        }
        return true
    }

    /// Scrolls to `origin` (kept within the rows), or to the top.
    private func scroll(to origin: NSPoint?) {
        let clip = scrollView.contentView
        // The clip view's insets include the header (and the path bar's room).
        let top = -clip.contentInsets.top
        let bottom = max(top, table.frame.height - clip.bounds.height + clip.contentInsets.bottom)
        let target = NSPoint(x: 0, y: min(max(origin?.y ?? top, top), bottom))
        // Scrolling, even to where it is, sets AppKit up for rubber-banding
        // (backgrounds twice the list's size): only when it moves.
        guard clip.bounds.origin != target else { return }
        clip.scroll(to: target)
        scrollView.reflectScrolledClipView(clip)
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row), let model, let column = FileColumn(tableColumn?.identifier) else { return nil }
        #if DEBUG
        UITestHarness.tick("FileListCell")
        #endif
        let cell = tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView ?? makeCell(column)
        fill(cell, with: rows[row], context: cellContext(model))
        return cell
    }

    private func cellContext(_ model: BrowserModel) -> CellContext {
        CellContext(browser: model, dateLevel: dateLevel,
                    statusAfterName: !ColumnSettings.shared.isShown(FileColumn.status.rawValue), iconPreviews: iconPreviews)
    }

    private func makeCell(_ column: FileColumn) -> NSTableCellView {
        #if DEBUG
        UITestHarness.tick("FileListCellMade")
        #endif
        switch column {
        case .name:
            let cell = NameCellView(identifier: column.identifier)
            cell.onToggle = { [weak self] item in self?.model?.toggleExpanded(item) }
            return cell
        case .modified: return TextCellView(identifier: column.identifier, font: CellFonts.digits, alignment: .left)
        case .size: return TextCellView(identifier: column.identifier, font: CellFonts.digits, alignment: .right)
        case .kind: return TextCellView(identifier: column.identifier, font: CellFonts.body, alignment: .left)
        case .status: return StatusCellView(identifier: column.identifier)
        }
    }

    /// Shows `item` in `cell` (whichever column it's from).
    private func fill(_ cell: NSTableCellView, with item: FileItem, context: CellContext) {
        switch cell {
        case let name as NameCellView:
            name.configure(item, context: context)
        case let status as StatusCellView:
            status.show(context.browser.operations.transfers.status(for: item))
        case let text as TextCellView:
            switch FileColumn(text.identifier) {
            case .modified:
                let forms = DateForms.forms(item.modified)
                text.show(forms[min(dateLevel, forms.count - 1)], help: forms[0])
            case .size:
                text.show(item.isDirectory ? "—" : item.size.formatted(.byteCount(style: .file)))
            case .kind:
                text.show(item.kind)
            default:
                break
            }
        default:
            break
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplying, let model else { return }
        let selected = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].id : nil })
        if model.selection != selected { model.selection = selected }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isApplying, let model, let descriptor = tableView.sortDescriptors.first,
              let column = FileColumn(rawValue: descriptor.key ?? ""), let sortColumn = column.sortColumn else { return }
        let order = [sortColumn.comparator(descriptor.ascending ? .forward : .reverse)]
        if model.sortOrder != order { model.sortOrder = order }
    }

    /// Type-select goes by name.
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        guard rows.indices.contains(row), FileColumn(tableColumn?.identifier) == .name else { return nil }
        return rows[row].name
    }

    /// Columns move, but Name stays first.
    func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
        columnIndex != 0 && newColumnIndex != 0
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        guard let column = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
              FileColumn(column.identifier) == .modified else { return }
        let level = DateForms.level(forWidth: column.width - 4, font: CellFonts.digits)
        guard level != dateLevel else { return }
        dateLevel = level
        // Never from inside the table's own resize.
        DispatchQueue.main.async { [weak self] in self?.refillVisibleRows() }
    }

    // MARK: Interaction

    /// Double-click: a folder opens in place, a local file in its app.
    @objc private func openClicked() {
        let row = table.clickedRow
        guard rows.indices.contains(row), let model else { return }
        cancelPendingRename()
        open(rows[row], in: model)
    }

    private func open(_ item: FileItem, in model: BrowserModel) {
        if item.isDirectory {
            model.open(item.location)
        } else if let url = item.location.localURL {
            NSWorkspace.shared.open(url)
        }
    }

    /// The list has the keyboard: its pane becomes the active one (a turn
    /// later, outside AppKit's focus change).
    func tableBecameFirstResponder() {
        guard let model else { return }
        DispatchQueue.main.async { [weak model] in
            if let model { BrowserModel.onInteraction?(model) }
        }
    }

    // MARK: Rows

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        tableView.makeView(withIdentifier: FileRowView.identifier, owner: nil) as? FileRowView ?? {
            let view = FileRowView()
            view.identifier = FileRowView.identifier
            return view
        }()
    }

    /// A row coming into view shows the drop marks if a drop would go into it.
    func tableView(_ tableView: NSTableView, didAdd rowView: NSTableRowView, forRow row: Int) {
        guard let rowView = rowView as? FileRowView else { return }
        rowView.isDropTarget = rows.indices.contains(row) && dropHover.value == .folder(rows[row].location)
    }
}

// MARK: The header's menu: which columns show (as View › Columns)

extension FileListCoordinator: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === table.headerView?.menu { fillHeaderMenu(menu) }
    }

    /// Which columns show, ticked; Name always does.
    func fillHeaderMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let name = NSMenuItem(title: FileColumn.name.title, action: nil, keyEquivalent: "")
        name.state = .on
        name.isEnabled = false
        menu.addItem(name)
        for column in ColumnSettings.optional {
            let item = ClosureMenuItem(column.title) { ColumnSettings.shared.toggle(column.id) }
            item.state = ColumnSettings.shared.isShown(column.id) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let all = ClosureMenuItem("Show All") {
            for column in ColumnSettings.optional { ColumnSettings.shared.set(column.id, shown: true) }
        }
        all.isEnabled = ColumnSettings.optional.contains { !ColumnSettings.shared.isShown($0.id) }
        menu.addItem(all)
    }
}

// MARK: The context menu

extension FileListCoordinator {
    /// For the row clicked (the selection, when the click was inside it), or
    /// for empty space: the folder's own menu, and the selection clears, as in
    /// Finder.
    func fillContextMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let model else { return }
        let row = table.clickedRow
        guard rows.indices.contains(row) else {
            if !model.selection.isEmpty { model.selection = [] }
            FileMenuBuilder.folderItems(in: model).forEach(menu.addItem)
            return
        }
        let items = table.selectedRowIndexes.contains(row)
            ? table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
            : [rows[row]]
        FileMenuBuilder.items(for: items, in: model).forEach(menu.addItem)
    }
}

// MARK: The keyboard (asked for by the window: a header click, a tab shown)

extension FileListCoordinator: ListKeyboardTarget {
    func takeKeyboardFocus() {
        guard let window = table.window, !scrollView.isHidden else {
            // Taken once the list can: nothing else keeps it meanwhile.
            keyboardPending = true
            if let window = table.window, window.firstResponder !== window { window.makeFirstResponder(nil) }
            return
        }
        guard window.firstResponder !== table else { return }
        // Not from a name being edited here.
        if let editor = window.firstResponder as? NSText, editor.delegate === renameField, renameField != nil { return }
        keyboardPending = false
        window.makeFirstResponder(table)
    }
}
