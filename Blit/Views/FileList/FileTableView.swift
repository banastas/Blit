// The AppKit file list's table and scroll view.

import AppKit

final class FileTableView: NSTableView {
    weak var coordinator: FileListCoordinator?

    /// No stripes beyond the ends while the list rubber-bands. AppKit keeps
    /// them in two backgrounds twice the list's size, about 20 MB a list, from
    /// the moment it shows. (This private AppKit method is the one SwiftUI's
    /// table overrides too; if AppKit stops asking, the list just costs more.)
    @objc func _needsRubberBandViews() -> Bool { false }

    /// → and ← open and close folders in place (Finder's list view); Return
    /// with several rows selected opens the first (one is renamed, by the
    /// app's key handling); Tab and ⇧Tab go to the other pane.
    override func keyDown(with event: NSEvent) {
        coordinator?.cancelPendingRename()
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let plain = modifiers.isEmpty
        let right: UInt16 = 124, left: UInt16 = 123, returnKey: UInt16 = 36, enter: UInt16 = 76, tab: UInt16 = 48
        if plain, event.keyCode == right || event.keyCode == left,
           coordinator?.expandSelection(event.keyCode == right) == true {
            return
        }
        if plain, event.keyCode == returnKey || event.keyCode == enter, coordinator?.openSelection() == true { return }
        if event.keyCode == tab, plain || modifiers == .shift, coordinator?.focusOtherPane() == true { return }
        super.keyDown(with: event)
    }

    /// A click makes the pane active at once; a click on the only selected
    /// row's name renames it a moment later (FileListRename.swift).
    override func mouseDown(with event: NSEvent) {
        coordinator?.noteInteraction()
        coordinator?.pressBegan(event)
        super.mouseDown(with: event)
        // The table's tracking may have taken the mouse-up; else it comes to
        // mouseUp(with:).
        if let up = NSApp.currentEvent, up.type == .leftMouseUp { coordinator?.pressEnded(up) }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        coordinator?.pressEnded(event)
    }

    override func rightMouseDown(with event: NSEvent) {
        coordinator?.cancelPendingRename()
        coordinator?.noteInteraction()
        super.rightMouseDown(with: event)
    }

    /// Right-clicks and ⌃-clicks ask for the menu here: it's filled for the
    /// row clicked (AppKit has just set it) before it shows.
    override func menu(for event: NSEvent) -> NSMenu? {
        coordinator?.noteInteraction()
        let menu = super.menu(for: event)
        if let menu { coordinator?.fillContextMenu(menu) }
        return menu
    }

    /// Finder's rule: a drag from a row's icon or name moves the files; from
    /// the rest of the row it selects rows as it goes.
    override func canDragRows(with rowIndexes: IndexSet, at mouseDownPoint: NSPoint) -> Bool {
        guard coordinator?.dragsFiles(from: mouseDownPoint) != false else { return false }
        return super.canDragRows(with: rowIndexes, at: mouseDownPoint)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        coordinator?.dragEntered(sender)
        return super.draggingEntered(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        super.draggingExited(sender)
        coordinator?.dragExited()
    }

    override func resignFirstResponder() -> Bool {
        coordinator?.cancelPendingRename()
        return super.resignFirstResponder()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { coordinator?.tableMovedToWindow() }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { coordinator?.tableBecameFirstResponder() }
        return became
    }
}

final class FileListScrollView: NSScrollView {}
