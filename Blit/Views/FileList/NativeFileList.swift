// The AppKit file list in SwiftUI. Being built to replace the SwiftUI Table
// (FileListView's): until then it shows only in debug test copies launched
// with -BlitNativeList YES.

import AppKit
import SwiftUI

enum FileListFlags {
    /// `-BlitNativeList YES`: the AppKit list, in debug builds only.
    static let native: Bool = {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "BlitNativeList")
        #else
        false
        #endif
    }()
}

/// A list that can take the keyboard for the pane it shows.
@MainActor
protocol ListKeyboardTarget: AnyObject {
    func takeKeyboardFocus()
}

struct NativeFileList: NSViewRepresentable {
    let browser: BrowserModel
    /// False while the pane shows an error or no folder: the list stays, hidden,
    /// for the next tab to use.
    var isShown: Bool
    /// Room under the rows for the path bar laid over them.
    var bottomInset: CGFloat
    /// Quick Look thumbnails for local files (View › Show Icon Previews).
    var iconPreviews: Bool
    // Plain values only (no closures): SwiftUI then leaves the list alone
    // when the window redraws and none of them changed (each update walks
    // every view in the list).

    func makeCoordinator() -> FileListCoordinator { FileListCoordinator() }

    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }

    func updateNSView(_ view: NSScrollView, context: Context) {
        #if DEBUG
        UITestHarness.tick("NativeFileList")
        #endif
        context.coordinator.update(browser: browser, isShown: isShown, bottomInset: bottomInset, iconPreviews: iconPreviews)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: FileListCoordinator) {
        coordinator.detach()
    }

    /// Whatever it's offered: never sized by its rows.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 300)
    }
}
