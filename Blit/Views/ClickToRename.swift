// Click to rename, as in Finder: a single click on the name of the file that's
// already the only one selected starts renaming it after the double-click
// interval (a second click in time makes it a double-click: open). Works in
// every file list (both panes, drives, NAS shares and servers).

import AppKit

@MainActor
enum ClickToRename {
    private static var monitor: Any?
    private static var pending: Task<Void, Never>?
    private struct Press {
        let table: NSTableView
        let row: Int
        let point: NSPoint
        let browser: BrowserModel
        let wasOnlySelection: Bool
        let onName: Bool
    }
    private static var press: Press?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated { handle(event) }
            return event
        }
    }

    private static func handle(_ event: NSEvent) {
        if event.type == .leftMouseDown {
            // Any new click (the second of a double-click, a click elsewhere) cancels a waiting rename.
            pending?.cancel()
            pending = nil
            press = nil
            guard event.clickCount == 1,
                  event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
                  let window = event.window, let browser = EmptySpaceMenu.browser(at: event.locationInWindow, in: window),
                  browser.renaming == nil, let table = fileList(at: event) else { return }
            let point = table.convert(event.locationInWindow, from: nil)
            let row = table.row(at: point)
            guard row >= 0, row < browser.rows.count else { return }
            let column = table.column(at: point)
            let item = browser.rows[row]
            // On the name itself: past the indent, disclosure triangle and icon.
            var onName = false
            if column >= 0, table.tableColumns[column].title == "Name" {
                let textStart = table.rect(ofColumn: column).minX + CGFloat(item.depth) * 16 + 44
                onName = point.x > textStart
            }
            press = Press(table: table, row: row, point: point, browser: browser,
                          wasOnlySelection: browser.selection == [item.location], onName: onName)
        } else if let press, event.clickCount == 1 {
            self.press = nil
            let point = press.table.convert(event.locationInWindow, from: nil)
            // A drag isn't a click.
            guard press.wasOnlySelection, press.onName, press.table.row(at: point) == press.row,
                  hypot(point.x - press.point.x, point.y - press.point.y) < 4 else { return }
            let browser = press.browser
            let row = press.row
            pending = Task { @MainActor in
                try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
                guard !Task.isCancelled, browser.renaming == nil, row < browser.rows.count else { return }
                let item = browser.rows[row]
                guard browser.selection == [item.location] else { return }
                browser.beginRename(item)
            }
        }
    }

    /// The file list (a table with column headers; the sidebar has none) under the click.
    private static func fileList(at event: NSEvent) -> NSTableView? {
        guard let content = event.window?.contentView,
              let hit = content.hitTest(content.convert(event.locationInWindow, from: nil)) else { return nil }
        var view: NSView? = hit
        while let current = view {
            if current is NSTableHeaderView { return nil }
            if let table = current as? NSTableView { return table.headerView != nil ? table : nil }
            view = current.superview
        }
        return nil
    }
}
