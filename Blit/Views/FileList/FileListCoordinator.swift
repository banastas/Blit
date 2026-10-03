// The AppKit file list (PRD R2.4–R2.6), being built to replace the SwiftUI
// Table: one table per pane, shared by every tab (a tab switch swaps the
// model and fills the rows on screen again, building no views), kept in step
// with the pane's BrowserModel by observation tracking. The model is the
// source of truth: the table shows its rows, selection and sort, and hands
// the user's changes back.

import AppKit
import Observation
import UniformTypeIdentifiers

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

    @MainActor
    init(_ model: BrowserModel) {
        folder = model.current
        rows = model.rows
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
    private var rowIndex: [BrowseLocation: Int] = [:]
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

    override init() {
        super.init()
        setUp()
    }

    isolated deinit {
        if let frameObserver { NotificationCenter.default.removeObserver(frameObserver) }
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
            MainActor.assumeIsolated { self?.scheduleFit() }
        }
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
        for column in table.tableColumns {
            guard let id = FileColumn(column.identifier) else { continue }
            let hide = !shown.contains(id) || (id == .size && result.sizeOut)
            if column.isHidden != hide { column.isHidden = hide }
            if !hide, let width = result.widths[id], abs(column.width - width) > 0.5 { column.width = width }
        }
        if let modified = table.tableColumn(withIdentifier: FileColumn.modified.identifier) {
            let level = DateForms.level(forWidth: modified.width - 4, font: CellFonts.digits)
            if level != dateLevel {
                dateLevel = level
                refillVisibleRows()
            }
        }
    }

    // MARK: The SwiftUI side

    func update(browser: BrowserModel, isShown: Bool, bottomInset: CGFloat) {
        if scrollView.isHidden == isShown { scrollView.isHidden = !isShown }
        if scrollView.contentInsets.bottom != bottomInset {
            scrollView.contentInsets.bottom = bottomInset
            scrollView.scrollerInsets.bottom = bottomInset
        }
        show(browser)
    }

    func detach() {
        watchGeneration += 1
        if let model {
            model.listScrollOrigin = scrollView.contentView.bounds.origin
            FileListRegistry.unregister(self, for: model)
        }
        model = nil
    }

    /// Shows `model`'s rows (another tab's pane, after a switch): all at once,
    /// in this update, with the selection, sort and scroll it had.
    private func show(_ model: BrowserModel) {
        guard model !== self.model else { return }
        if let old = self.model {
            old.listScrollOrigin = scrollView.contentView.bounds.origin
            FileListRegistry.unregister(self, for: old)
        }
        self.model = model
        FileListRegistry.register(self, for: model)
        let snapshot = watch(model)
        isApplying = true
        showColumns(hidden: snapshot.hiddenColumns)
        shownFolder = snapshot.folder
        replaceRows(snapshot.rows)
        showSelection(snapshot.selection)
        showSort(snapshot.sort)
        isApplying = false
        scroll(to: model.listScrollOrigin)
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
        if snapshot.folder != shownFolder {
            shownFolder = snapshot.folder
            replaceRows(snapshot.rows)
            scroll(to: nil)
        } else if snapshot.rows != rows {
            replaceRows(snapshot.rows)
        }
        showSelection(snapshot.selection)
        showSort(snapshot.sort)
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
        table.enumerateAvailableRowViews { rowView, row in
            guard self.rows.indices.contains(row) else { return }
            for column in 0..<rowView.numberOfColumns {
                guard let cell = rowView.view(atColumn: column) as? NSTableCellView else { continue }
                self.fill(cell, with: self.rows[row], model: model)
            }
        }
    }

    private func setRows(_ new: [FileItem]) {
        rows = new
        rowIndex = Dictionary(new.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
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
    /// fit them again.
    private var shownHidden: Set<String>?
    private func showColumns(hidden: Set<String>) {
        guard hidden != shownHidden else { return }
        shownHidden = hidden
        scheduleFit(force: true)
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
        fill(cell, with: rows[row], model: model)
        return cell
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
    private func fill(_ cell: NSTableCellView, with item: FileItem, model: BrowserModel) {
        switch cell {
        case let name as NameCellView:
            name.configure(item, context: CellContext(browser: model, dateLevel: dateLevel,
                                                      statusAfterName: !ColumnSettings.shared.isShown(FileColumn.status.rawValue)))
        case let status as StatusCellView:
            status.show(model.operations.transfers.status(for: item))
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
        let item = rows[row]
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

    // MARK: Drops (a first probe: what arrives, and where it goes)

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        #if DEBUG
        UITestHarness.dropTrail.append("native validate row \(row) \(operation == .on ? "on" : "above")")
        #endif
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let model, let folder = model.current else { return false }
        let sources = DropReader.locations(on: info.draggingPasteboard)
        #if DEBUG
        UITestHarness.dropTrail.append("native accept \(sources.count)")
        #endif
        var target = folder
        var name = model.title
        if dropOperation == .on, rows.indices.contains(row), rows[row].isDirectory {
            target = rows[row].location
            name = rows[row].name
        }
        let moving = sources.filter { $0 != target }
        guard !moving.isEmpty else { return false }
        model.drop(moving, into: target, name: name, copy: NSEvent.modifierFlags.contains(.option))
        return true
    }
}
