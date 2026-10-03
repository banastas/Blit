// The file list's columns (PRD R2.6): Name, Modified, Size, Status and Kind.
// Which ones show is ColumnSettings' (shared by both panes and View ›
// Columns); Name always shows.

import AppKit

/// A column of the file list. The raw value is both the table column's
/// identifier and its id in ColumnSettings.
enum FileColumn: String, CaseIterable {
    case name, modified, size, status, kind

    var title: String {
        switch self {
        case .name: "Name"
        case .modified: "Modified"
        case .size: "Size"
        case .status: "Status"
        case .kind: "Kind"
        }
    }

    var minWidth: CGFloat {
        switch self {
        case .name: 110
        case .modified: 64
        case .size: 54
        case .status, .kind: 70
        }
    }

    var idealWidth: CGFloat {
        switch self {
        case .name: 280
        case .modified: 132
        case .size: 70
        case .status: 110
        case .kind: 120
        }
    }

    /// How the column sorts (Status doesn't).
    var sortColumn: SortColumn? {
        switch self {
        case .name: .name
        case .modified: .modified
        case .size: .size
        case .kind: .kind
        case .status: nil
        }
    }

    var identifier: NSUserInterfaceItemIdentifier { NSUserInterfaceItemIdentifier(rawValue) }

    init?(_ identifier: NSUserInterfaceItemIdentifier?) {
        guard let identifier, let column = Self(rawValue: identifier.rawValue) else { return nil }
        self = column
    }

    init?(_ sortColumn: SortColumn) {
        guard let column = Self.allCases.first(where: { $0.sortColumn == sortColumn }) else { return nil }
        self = column
    }

    /// The header-click sort, starting the way Finder's does (names A–Z,
    /// dates and sizes largest first).
    var sortPrototype: NSSortDescriptor? {
        sortColumn.map { NSSortDescriptor(key: rawValue, ascending: $0.defaultOrder == .forward) }
    }
}

/// Fits the columns to a pane's width, worked out from the width alone so the
/// same width always gives the same columns. Every column but Name has a set
/// width and Name takes the rest. Only if that would push Name under its
/// minimum do Modified, then Size, give up width (the date then shows a
/// shorter form); if even that isn't enough, Size steps out until there's
/// room again, with 20 pt to spare so it doesn't flap.
enum ColumnFit {
    static let fixedWidths: [FileColumn: CGFloat] = [.modified: 132, .size: 70, .status: 100, .kind: 120]

    struct Result: Equatable {
        var widths: [FileColumn: CGFloat]
        /// Size is out for want of room (not by the user's choice).
        var sizeOut: Bool
    }

    /// `shown`: the columns the user shows, Name first. `margins`: the list
    /// style's margins at both ends, plus room for an overlay scroller.
    static func fit(room: CGFloat, shown: [FileColumn], sizeOut: Bool, spacing: CGFloat, margins: CGFloat) -> Result {
        func needed(_ columns: [FileColumn], _ width: (FileColumn) -> CGFloat) -> CGFloat {
            columns.reduce(CGFloat(0)) { $0 + width($1) + spacing } + margins
        }
        var out = false
        if shown.contains(.size) {
            let atMinimum = needed(shown) { $0.minWidth }
            out = sizeOut ? room < atMinimum + 20 : room < atMinimum
        }
        let columns = shown.filter { !(out && $0 == .size) }
        var widths: [FileColumn: CGFloat] = [:]
        for column in columns where column != .name { widths[column] = fixedWidths[column] ?? column.idealWidth }
        var total = needed(columns) { $0 == .name ? $0.minWidth : widths[$0] ?? $0.idealWidth }
        for column in [FileColumn.modified, .size] where total > room {
            guard let current = widths[column] else { continue }
            let give = min(total - room, current - column.minWidth)
            if give > 0 {
                widths[column] = current - give
                total -= give
            }
        }
        let others = columns.filter { $0 != .name }.reduce(CGFloat(0)) { $0 + (widths[$1] ?? 0) + spacing }
        widths[.name] = max(FileColumn.name.minWidth, room - margins - spacing - others)
        return Result(widths: widths, sizeOut: out)
    }

    /// How much of `scrollView` the window's floating sidebar covers (0 when
    /// it's hidden or beside the list rather than over it).
    @MainActor
    static func sidebarOverlap(_ scrollView: NSScrollView) -> CGFloat {
        guard let content = scrollView.window?.contentView else { return 0 }
        var sidebar: NSView?
        func find(_ view: NSView) {
            if sidebar != nil { return }
            if let outline = view as? NSOutlineView, outline.headerView == nil { sidebar = outline.enclosingScrollView ?? outline; return }
            view.subviews.forEach(find)
        }
        find(content)
        guard let sidebar, !sidebar.isHiddenOrHasHiddenAncestor else { return 0 }
        let list = scrollView.convert(scrollView.bounds, to: nil)
        let side = sidebar.convert(sidebar.bounds, to: nil)
        return max(0, min(list.maxX, side.maxX) - max(list.minX, side.minX))
    }
}
