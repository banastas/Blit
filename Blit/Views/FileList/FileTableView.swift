// The AppKit file list's table and scroll view.

import AppKit

final class FileTableView: NSTableView {
    weak var coordinator: FileListCoordinator?

    /// No springs: the table keeps to the pane's width itself (NSTableView
    /// follows its clip view, and the coordinator fits the columns). AppKit
    /// gives a scroll view's document view a flexible width and height, which
    /// kept whatever gap there once was between the table and the pane across
    /// resizes, and Auto Layout put it back after each fit: a table wider than
    /// the pane, scrolling sideways into empty space.
    override var autoresizingMask: NSView.AutoresizingMask {
        get { [] }
        set {}
    }

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
        if let field = coordinator?.renameField {
            // A click the field didn't take (it ends editing, as in Finder): where.
            let point = convert(event.locationInWindow, from: nil)
            let onField = field.convert(field.bounds, to: self).contains(point)
            RenameLog.note("click on row \(row(at: point)), column \(column(at: point)) while editing\(onField ? ", inside the field's frame" : "")")
        }
        // ⌃-click: the menu at once, as a right-click does (with rows draggable,
        // the table first waited for the button to come up; and its right-click
        // handling ignores a left button).
        if event.modifierFlags.contains(.control) {
            coordinator?.cancelPendingRename()
            if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            return
        }
        coordinator?.noteInteraction()
        if coordinator?.toggleDisclosure(at: event) == true { return }
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
        if coordinator?.renameField != nil { RenameLog.note("right-click on row \(row(at: convert(event.locationInWindow, from: nil))) while editing") }
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

    private var closeObserver: (any NSObjectProtocol)?


    /// Follows the window it's in: takes the keyboard if it was asked for
    /// before, and lets go of its pane when the window closes.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        guard let window else { return }
        closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window,
                                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.coordinator?.detach() }
        }
        coordinator?.tableMovedToWindow()
    }

    isolated deinit {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { coordinator?.tableBecameFirstResponder() }
        return became
    }
}

final class FileListScrollView: NSScrollView {}
