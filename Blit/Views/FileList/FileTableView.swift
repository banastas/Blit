// The AppKit file list's table and scroll view.

import AppKit

final class FileTableView: NSTableView {
    weak var coordinator: FileListCoordinator?

    /// No stripes beyond the ends while the list rubber-bands. AppKit keeps
    /// them in two backgrounds twice the list's size, about 20 MB a list, from
    /// the moment it shows. (This private AppKit method is the one SwiftUI's
    /// table overrides too; if AppKit stops asking, the list just costs more.)
    @objc func _needsRubberBandViews() -> Bool { false }

    /// → and ← open and close folders in place (Finder's list view).
    override func keyDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        let right: UInt16 = 124, left: UInt16 = 123
        if plain, event.keyCode == right || event.keyCode == left,
           coordinator?.expandSelection(event.keyCode == right) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { coordinator?.tableBecameFirstResponder() }
        return became
    }
}

final class FileListScrollView: NSScrollView {}
