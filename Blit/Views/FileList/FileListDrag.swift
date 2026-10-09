// Dragging rows out of the AppKit file list and dropping onto it (PRD R2.3).
// A drag that starts on a row's icon or name moves the files (Finder's rule:
// from the rest of the row it selects rows as it goes). Each dragged row
// carries Blit's payload, and a local row its file too, so Finder and other
// apps take the file; a server row carries the payload only, which only Blit
// takes. A drop goes into the folder row under the pointer (or the folder
// holding the file there, in an expanded folder), which lights up in Blit's
// pixel look; anywhere else, into the list's own folder, which outlines.

import AppKit
import UniformTypeIdentifiers

extension NSPasteboard.PasteboardType {
    /// Blit's own drag payload: a TransferPayload, as JSON.
    static let blitLocations = NSPasteboard.PasteboardType(UTType.blitLocations.identifier)
}

// MARK: Dragging rows

extension FileListCoordinator {
    /// Finder's rule for a drag that starts on a row: from the icon or the
    /// name (with the marks after it, and a little room past them, as Blit's
    /// list has allowed since 0.2.26) it moves the files; from the rest of the
    /// row it selects rows as it goes.
    func dragsFiles(from point: NSPoint) -> Bool {
        let row = table.row(at: point)
        guard rows.indices.contains(row), table.column(at: point) == 0,
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NameCellView else { return false }
        return cell.convert(point, from: table).x <= min(cell.contentEnd + 18, cell.bounds.width)
    }

    /// One pasteboard item per dragged row (the selection when the row is in
    /// it, else just the row, as in Finder): its file (local rows), first, as
    /// other apps take the first type they can use; then Blit's payload, which
    /// Blit's own drop targets read first. Every target reads every item's, so
    /// the first dragged row's holds them all and the others just their own
    /// (each holding all made a 5,000-row drag 25 million entries).
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard rows.indices.contains(row) else { return nil }
        let item = rows[row]
        let selected = table.selectedRowIndexes
        let carried = selected.contains(row) && row == selected.first
            ? selected.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
            : [item]
        let payload = TransferPayload(locations: carried.map(\.location), folders: carried.filter(\.isDirectory).map(\.location),
                                      primary: item.location)
        let board = NSPasteboardItem()
        if let url = item.location.localURL { board.setString(url.absoluteString, forType: .fileURL) }
        if let data = try? JSONEncoder().encode(payload) { board.setData(data, forType: .blitLocations) }
        return board
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        cancelPendingRename()
        let dragged = rowIndexes.compactMap { rows.indices.contains($0) ? rows[$0] : nil }
        DragContents.started(TransferPayload(locations: dragged.map(\.location),
                                             folders: dragged.filter(\.isDirectory).map(\.location)))
        if let model { DragSize.shared.measure(dragged, in: model) }
        #if DEBUG
        UITestHarness.dropTrail.append("drag began \(dragged.map(\.name))")
        #endif
    }
}

// MARK: Drops

extension FileListCoordinator {
    /// Where a drop at the pointer would go: the folder row under it, or the
    /// folder holding the file under it (in an expanded folder); never a
    /// folder being dragged, or one inside it. Anywhere else, the list's folder.
    func dropTarget(_ info: NSDraggingInfo) -> ListDrop {
        let row = table.row(at: table.convert(info.draggingLocation, from: nil))
        guard rows.indices.contains(row) else { return .list }
        let item = rows[row]
        guard let folder = item.isDirectory ? item.location : item.depth > 0 ? item.location.parent : nil,
              rowIndex[folder] != nil else { return .list }
        // What's dragged, not what's selected here: a drag from the other pane
        // can drop on a folder selected in this one.
        let dragged = draggedLocations(info)
        guard !dragged.contains(where: { FileOperations.location($0, textuallyContains: folder) }) else { return .list }
        return .folder(folder)
    }

    /// What the drag in progress carries, read once per drag.
    private func draggedLocations(_ info: NSDraggingInfo) -> [BrowseLocation] {
        if let dragged, dragged.sequence == info.draggingSequenceNumber { return dragged.locations }
        let locations = DropReader.locations(on: info.draggingPasteboard)
        dragged = (info.draggingSequenceNumber, locations)
        return locations
    }

    /// A drag came over the list.
    func dragEntered(_ info: NSDraggingInfo) {
        #if DEBUG
        UITestHarness.dropTrail.append("entered")
        #endif
        DragSize.shared.note(info.draggingPasteboard)
        dropHover.entered(dropTarget(info))
        showDropMark()
    }

    /// It left the list without dropping.
    func dragExited() {
        #if DEBUG
        UITestHarness.dropTrail.append("exited")
        #endif
        dropHover.exited()
        showDropMark()
        springLoad(nil)
    }

    /// Spring loading, as in Finder (System Settings' switch and delay): a
    /// drag resting on a closed folder opens it in place, so it can go
    /// deeper without letting go.
    func springLoad(_ target: ListDrop?) {
        let folder: BrowseLocation? = if case .folder(let location) = target { location } else { nil }
        guard folder != springFolder else { return }
        springTimer?.invalidate()
        springTimer = nil
        springFolder = folder
        let defaults = UserDefaults.standard
        guard let folder, let model, !model.expanded.contains(folder),
              defaults.object(forKey: "com.apple.springing.enabled") as? Bool ?? true else { return }
        let delay = defaults.object(forKey: "com.apple.springing.delay") as? Double ?? 0.5
        let timer = Timer(timeInterval: max(0.2, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.springFolder == folder, self.dropHover.value == .folder(folder),
                      let model = self.model, !model.expanded.contains(folder) else { return }
                #if DEBUG
                UITestHarness.dropTrail.append("spring-loaded \(folder.lastComponent)")
                #endif
                model.setExpanded(folder, true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)   // a drag runs the loop in its tracking mode
        springTimer = timer
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard model?.current != nil else { return [] }
        let target = dropTarget(info)
        // The row it goes into (AppKit's own drop marks are off: Blit draws its own).
        if case .folder(let folder) = target, let index = rowIndex[folder] {
            tableView.setDropRow(index, dropOperation: .on)
        } else {
            tableView.setDropRow(-1, dropOperation: .on)
        }
        #if DEBUG
        UITestHarness.dropTrail.append("updated")
        #endif
        dropHover.moved(target)
        showDropMark()
        springLoad(target)
        return NSEvent.modifierFlags.contains(.option) ? .copy : .move
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        let target = dropTarget(info)
        let copy = NSEvent.modifierFlags.contains(.option)
        dropHover.dropped()
        showDropMark()
        springLoad(nil)
        guard let model else { return false }
        #if DEBUG
        let started = Date()
        let items = info.draggingPasteboard.pasteboardItems?.count ?? 0
        UITestHarness.dropTrail.append("perform \(items)")
        #endif
        let sources = DropReader.locations(on: info.draggingPasteboard)
        let local = sources.filter { $0.localURL != nil }.count
        DropLog.note("list drop: keys \(DropLog.keys(NSEvent.modifierFlags)) · the event's \(DropLog.keys(NSApp.currentEvent?.modifierFlags ?? [])) · "
                     + "allowed \(DropLog.operations(info.draggingSourceOperationMask)) · onto \(target == .list ? "the list" : "a folder row") · "
                     + "\(sources.count) items (\(local) local)")
        let accepted = drop(sources, onto: target, copy: copy, in: model)
        #if DEBUG
        let onto = if case .folder(let folder) = target { folder.lastComponent } else { "the list" }
        UITestHarness.lastDrop = "\(items) items · \(sources.count) sources · read in \(Int(Date().timeIntervalSince(started) * 1000)) ms · onto \(onto) · accepted \(accepted)"
        #endif
        return accepted
    }

    /// Drops `sources` into the folder `target` names. `copy` is ⌥ as it was
    /// at the drop.
    private func drop(_ sources: [BrowseLocation], onto target: ListDrop, copy: Bool, in model: BrowserModel) -> Bool {
        let folder: BrowseLocation?, name: String
        switch target {
        case .folder(let location): (folder, name) = (location, location.lastComponent)
        case .list: (folder, name) = (model.current, model.title)
        }
        guard let folder else { return false }
        let sources = sources.filter { $0 != folder }
        guard !sources.isEmpty else { return false }
        model.drop(sources, into: folder, name: name, copy: copy)
        return true
    }

    /// Lights the folder row a drop would go into, or outlines the list (or
    /// neither); also after rows are refilled, so a folder stays lit across a
    /// reload mid-drag.
    func showDropMark() {
        let value = dropHover.value
        if value == .list {
            var frame = scrollView.bounds
            frame.origin.y += scrollView.contentInsets.bottom
            frame.size.height -= scrollView.contentInsets.bottom
            listOutline.frame = frame.insetBy(dx: 3, dy: 3)
            // Over the column headers too (the scroll view puts its header on top when it tiles).
            if scrollView.subviews.last !== listOutline { scrollView.addSubview(listOutline, positioned: .above, relativeTo: nil) }
        }
        listOutline.isHidden = value != .list
        table.enumerateAvailableRowViews { rowView, row in
            guard let rowView = rowView as? FileRowView else { return }
            rowView.isDropTarget = self.rows.indices.contains(row) && value == .folder(self.rows[row].location)
        }
        showDropSpace(value)
    }

    /// The free space the drop would leave, at the foot of the list.
    private func showDropSpace(_ value: ListDrop?) {
        let destination: BrowseLocation? = switch value {
        case .folder(let folder): folder
        case .list: model?.current
        case nil: nil
        }
        guard let destination, let summary = DropSpace.summary(into: destination, compact: false) else {
            dropSpace.isHidden = true
            return
        }
        dropSpace.show(summary)
        let size = dropSpace.fittingSize
        let bounds = scrollView.bounds
        // Just above the path bar, whichever way the scroll view counts.
        let gap = scrollView.contentInsets.bottom + 10
        dropSpace.frame = NSRect(x: (bounds.midX - size.width / 2).rounded(),
                                 y: scrollView.isFlipped ? bounds.maxY - gap - size.height : bounds.minY + gap,
                                 width: size.width, height: size.height)
        if scrollView.subviews.last !== dropSpace { scrollView.addSubview(dropSpace, positioned: .above, relativeTo: nil) }
        dropSpace.isHidden = false
    }

    /// Follows the hover's own clearing (no mouse button down for a moment:
    /// a drag that ended somewhere AppKit didn't say), and, while a drop would
    /// land here, the drag's size and the free space as they come in.
    func watchDropHover() {
        let hover = dropHover
        dropWatch = Task { [weak self] in
            for await _ in Observations({ () -> Int in
                var hasher = Hasher()
                hasher.combine(hover.value == nil)
                if case .folder(let folder) = hover.value { hasher.combine(folder) }
                if hover.value != nil {
                    hasher.combine(DragSize.shared.bytes)
                    hasher.combine(FreeSpace.shared.bytes)
                }
                return hasher.finalize()
            }) {
                self?.showDropMark()
            }
        }
    }

    #if DEBUG
    /// Row views showing the drop marks now (the drag tests).
    var litRowViews: Int {
        var count = 0
        table.enumerateAvailableRowViews { rowView, _ in if (rowView as? FileRowView)?.isDropTarget == true { count += 1 } }
        return count
    }
    #endif
}

// MARK: The marks

/// "1.2 TB free → 0.9 TB after" over the foot of a list while a drop would
/// go into it (PRD R2.10): in the drop marks' accent colour, or orange when it
/// won't fit. Never in the way: it takes no clicks or drags.
final class DropSpaceLabel: NSView {
    private(set) var summary: DropSpace.Summary?
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)

    init() {
        super.init(frame: .zero)
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    func show(_ summary: DropSpace.Summary) {
        guard summary != self.summary else { return }
        self.summary = summary
        setAccessibilityLabel(summary.text)
        needsDisplay = true
    }

    override var fittingSize: NSSize {
        NSSize(width: CellDrawing.width(summary?.text ?? "", font: Self.font) + 16, height: CellDrawing.lineHeight(Self.font) + 6)
    }

    override func draw(_ dirtyRect: NSRect) {
        (summary?.fits == false ? NSColor.systemOrange : NSColor.controlAccentColor).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
        CellDrawing.draw(summary?.text ?? "", in: bounds.insetBy(dx: 8, dy: 0), font: Self.font, color: .white,
                         alignment: .center, lineBreak: .byClipping)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// A row of the AppKit file list. When a drop would go into its folder, its
/// Name cell lights up: the accent fill behind it and marching ants around it.
final class FileRowView: NSTableRowView {
    static let identifier = NSUserInterfaceItemIdentifier("FileRow")

    var isDropTarget = false {
        didSet {
            guard isDropTarget != oldValue else { return }
            if isDropTarget {
                addSubview(ants)
                needsLayout = true
            } else {
                ants.removeFromSuperview()
            }
            needsDisplay = true
        }
    }

    private let ants = PixelAntsView(cell: 1.5)

    /// Where the Name cell is: the marks go around its content (the icon and
    /// name, about 16 pt tall).
    private func markRect(outset: CGFloat, height: CGFloat) -> NSRect? {
        guard let cell = view(atColumn: 0) as? NSView else { return nil }
        let frame = cell.frame
        return NSRect(x: frame.minX - outset, y: frame.midY - height / 2, width: frame.width + outset * 2, height: height)
    }

    override func layout() {
        super.layout()
        if isDropTarget, let rect = markRect(outset: 1, height: 16) { ants.frame = rect }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isDropTarget, let rect = markRect(outset: 2, height: 20) else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
    }
}

/// Pixel "marching ants" around its bounds, as PixelMarchingAnts draws them:
/// square cells, two on and two off, stepping clockwise every 0.12 s while it
/// shows. Never takes a click or a drag.
final class PixelAntsView: NSView {
    private let cell: CGFloat
    private var timer: Timer?

    init(cell: CGFloat) {
        self.cell = cell
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTimer()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateTimer()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateTimer()
    }

    private func updateTimer() {
        let running = window != nil && !isHiddenOrHasHiddenAncestor
        if running, timer == nil {
            let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.needsDisplay = true }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
            needsDisplay = true
        } else if !running {
            timer?.invalidate()
            timer = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let phase = Int(Date.timeIntervalSinceReferenceDate / 0.12) % 4
        let columns = max(2, Int(bounds.width / cell)), rows = max(2, Int(bounds.height / cell))
        // The perimeter, clockwise from the top left.
        var cells: [(Int, Int)] = (0..<columns).map { ($0, 0) }
        cells += (1..<rows).map { (columns - 1, $0) }
        cells += (0..<(columns - 1)).reversed().map { ($0, rows - 1) }
        cells += (1..<(rows - 1)).reversed().map { (0, $0) }
        NSColor.labelColor.setFill()
        for (index, (x, y)) in cells.enumerated() where (index + 4 - phase) % 4 < 2 {
            NSRect(x: bounds.minX + CGFloat(x) * cell, y: bounds.minY + CGFloat(y) * cell, width: cell, height: cell)
                .fill(using: .sourceOver)
        }
    }
}
