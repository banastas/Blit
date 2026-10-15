// Clear Queue… (PRD R5.2): every transfer out of the queue at once, from the
// HUD's queue panel, the strip's right-click menu and View › Clear Queue….
// It asks first when anything would stop or be cancelled.

import AppKit
import SwiftUI

@MainActor
enum ClearQueue {
    static func confirm(_ transfers: TransferManager) {
        let unfinished = transfers.unfinishedCount, all = transfers.transferJobs.count
        guard unfinished > 0 else { return transfers.clearQueue() }
        let alert = NSAlert()
        alert.messageText = "Clear the queue?"
        let stops = unfinished == 1 ? "1 transfer that hasn't finished" : "\(unfinished) transfers that haven't finished"
        let removes = all == unfinished ? "" : ", and all \(all) leave the queue"
        alert.informativeText = "This stops or cancels \(stops)\(removes). Files already transferred stay where they are. "
            + "A download's part files stay too, so it can be resumed from the file list."
        alert.addButton(withTitle: "Clear Queue")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        transfers.clearQueue()
    }
}

/// View › Clear Queue…: a view of its own, so the menu item enables as the
/// queue changes (a Commands body doesn't follow what it reads).
struct ClearQueueMenuItem: View {
    let transfers: TransferManager

    var body: some View {
        Button("Clear Queue…") { ClearQueue.confirm(transfers) }
            .disabled(transfers.transferJobs.isEmpty)
    }
}
