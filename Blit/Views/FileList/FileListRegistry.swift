// Which AppKit file list shows which pane: lets the window, the tab bar and
// the tests reach a pane's table without searching the view tree for it.

import AppKit

@MainActor
enum FileListRegistry {
    private static let coordinators = NSMapTable<BrowserModel, FileListCoordinator>.weakToWeakObjects()

    static func register(_ coordinator: FileListCoordinator, for model: BrowserModel) {
        coordinators.setObject(coordinator, forKey: model)
    }

    /// Forgets `model`'s list, if it's still `coordinator` (the list may have
    /// moved on to show another tab's pane).
    static func unregister(_ coordinator: FileListCoordinator, for model: BrowserModel) {
        if coordinators.object(forKey: model) === coordinator { coordinators.removeObject(forKey: model) }
    }

    static func coordinator(for model: BrowserModel) -> FileListCoordinator? {
        coordinators.object(forKey: model)
    }

    static func table(for model: BrowserModel) -> NSTableView? { coordinator(for: model)?.table }

    static func scrollView(for model: BrowserModel) -> NSScrollView? { coordinator(for: model)?.scrollView }

    /// The pane whose list shows at `point` (window coordinates), if any.
    static func browser(at point: NSPoint, in window: NSWindow) -> BrowserModel? {
        for case let model as BrowserModel in coordinators.keyEnumerator().allObjects {
            guard let scrollView = scrollView(for: model), scrollView.window === window,
                  !scrollView.isHiddenOrHasHiddenAncestor else { continue }
            if scrollView.convert(scrollView.bounds, to: nil).contains(point) { return model }
        }
        return nil
    }
}
