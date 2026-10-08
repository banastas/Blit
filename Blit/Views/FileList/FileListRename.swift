// Renaming in the AppKit file list (PRD R2.12): a native field over the name
// (it scrolls a long name within its width), the base name selected; Return
// or clicking away saves, Esc cancels. A click on the name of the only
// selected row starts it after the double-click interval, as in Finder (a
// second click in time opens instead).

import AppKit

/// A press on a row, kept until the mouse comes up (click to rename).
struct ListPress {
    let row: Int
    let point: NSPoint
    let item: FileItem
    let wasOnlySelection: Bool
    let onName: Bool
}

extension FileListCoordinator: NSTextFieldDelegate {
    /// Follows the model's `renaming`: starts editing that row once it's in
    /// the list (a new folder's row comes a moment after), or stops.
    func showRenaming(_ location: BrowseLocation?) {
        guard let location else {
            if renameField != nil { removeRenameField() }
            return
        }
        guard renamingItem?.id != location || renameField == nil, let row = rowIndex[location] else { return }
        beginEditing(rows[row], row: row)
    }

    private func beginEditing(_ item: FileItem, row: Int) {
        removeRenameField()
        cancelPendingRename()
        table.scrollRowToVisible(row)
        guard let model, let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NameCellView else { return }
        let field = NSTextField(string: item.name)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.font = CellFonts.body
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.maximumNumberOfLines = 1
        field.delegate = self
        cell.beginEditing(with: field)
        renameField = field
        renamingItem = item
        renamingModel = model
        renameFinished = false
        table.window?.makeFirstResponder(field)
        // The base name: all of it for folders, names without an extension, or
        // an "extension" with a space (a dot in a title).
        let name = item.name as NSString
        let ext = name.pathExtension
        let length = item.isDirectory || ext.isEmpty || ext.contains(" ") ? name.length : name.length - (ext as NSString).length - 1
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: max(0, length))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === renameField else { return false }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            finishRename(nil)
            return true
        }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            finishRename(control.stringValue)
            return true
        }
        return false
    }

    /// Clicking elsewhere (or Tab) ends editing: save, as Finder does.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, field === renameField else { return }
        finishRename(field.stringValue)
    }

    /// Saves `text` as the name (nil cancels), once.
    private func finishRename(_ text: String?) {
        guard !renameFinished, let item = renamingItem, let model = renamingModel else { return }
        renameFinished = true
        #if DEBUG
        UITestHarness.renameTrail.append("finished (\(text == nil ? "cancel" : "commit")) · " + UITestHarness.callers())
        #endif
        // Still in the field (Return, Esc): the keyboard goes back to the list.
        // Ended by a click elsewhere: it stays where it went.
        let refocus = (table.window?.firstResponder as? NSText)?.delegate === renameField
        if let text {
            model.commitRename(item, to: text)
        } else {
            model.cancelRename()
        }
        removeRenameField()
        if refocus { table.window?.makeFirstResponder(table) }
    }

    func removeRenameField() {
        guard let field = renameField else { return }
        #if DEBUG
        UITestHarness.renameTrail.append("field removed · " + UITestHarness.callers())
        #endif
        renameFinished = true
        renameField = nil
        renamingItem = nil
        field.delegate = nil
        (field.superview as? NameCellView)?.endEditing()
        field.removeFromSuperview()
        // What changed while the name was edited shows now (unless the list
        // has moved on to another tab's pane meanwhile).
        if rowsWaitingForRename {
            rowsWaitingForRename = false
            let generation = watchGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, let model = self.model, self.watchGeneration == generation else { return }
                self.refresh(from: model)
            }
        }
    }

    // MARK: Click to rename

    /// A press on a row: remembered until the mouse comes up.
    func pressBegan(_ event: NSEvent) {
        cancelPendingRename()
        press = nil
        #if DEBUG
        let pressed = table.convert(event.locationInWindow, from: nil)
        pressedOffName = table.row(at: pressed) >= 0 && !dragsFiles(from: pressed)
        #endif
        guard event.clickCount == 1, event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty,
              let model, model.renaming == nil else { return }
        let point = table.convert(event.locationInWindow, from: nil)
        let row = table.row(at: point)
        guard rows.indices.contains(row),
              let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NameCellView else { return }
        let item = rows[row]
        // On the name: in the Name column, past the indent, disclosure triangle
        // and icon (the space after a short name counts, as it always has).
        let onName = table.column(at: point) == 0 && cell.convert(point, from: table).x >= cell.nameRect.minX
        press = ListPress(row: row, point: point, item: item, wasOnlySelection: model.selection == [item.id], onName: onName)
    }

    /// The mouse came up: a click on the only selected row's name renames it,
    /// unless a second click follows in time.
    func pressEnded(_ event: NSEvent) {
        defer { press = nil }
        guard let press, event.type == .leftMouseUp, event.clickCount == 1,
              press.wasOnlySelection, press.onName, let model else { return }
        let point = table.convert(event.locationInWindow, from: nil)
        guard table.row(at: point) == press.row, hypot(point.x - press.point.x, point.y - press.point.y) < 4 else { return }
        let item = press.item
        pendingRename = Task { @MainActor [weak self, weak model] in
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval))
            guard !Task.isCancelled, let self, let model, self.model === model, model.renaming == nil,
                  model.selection == [item.id], self.table.window?.firstResponder === self.table else { return }
            model.beginRename(item)
        }
    }

    func cancelPendingRename() {
        pendingRename?.cancel()
        pendingRename = nil
    }
}
