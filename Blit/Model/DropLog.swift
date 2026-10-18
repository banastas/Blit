// A record of drops (PRD R2.3) in the system log. A drag within one drive
// should move the files (a rename), but on 9 October two drags on the user's
// drive copied them (APFS clones) instead, which no test copy did. Each drop's
// modifier keys and allowed operations, and how each item was placed, and
// why. No file names.
//
//   log show --last 2h --info --predicate 'subsystem == "com.banastas.blit" && category == "drop"'

import AppKit
import os

enum DropLog {
    private static let logger = Logger(subsystem: "com.banastas.blit", category: "drop")

    @MainActor static func note(_ event: String) {
        logger.notice("\(event, privacy: .public)")
        #if DEBUG
        UITestHarness.dropLog.append(event)
        #endif
    }

    /// "⌥⌘", or "none".
    static func keys(_ flags: NSEvent.ModifierFlags) -> String {
        let named: [(NSEvent.ModifierFlags, String)] = [(.option, "⌥"), (.command, "⌘"), (.control, "⌃"), (.shift, "⇧"), (.capsLock, "⇪")]
        let held = named.filter { flags.contains($0.0) }.map(\.1).joined()
        return held.isEmpty ? "none" : held
    }

    /// "copy+move", or "none".
    static func operations(_ operation: NSDragOperation) -> String {
        let named: [(NSDragOperation, String)] = [(.copy, "copy"), (.move, "move"), (.link, "link"), (.generic, "generic"), (.delete, "delete")]
        let allowed = named.filter { operation.contains($0.0) }.map(\.1).joined(separator: "+")
        return allowed.isEmpty ? "none" : allowed
    }
}

/// Quick Look keys (Space, ↑/↓, Return, Esc over the list) that Blit let pass
/// for an unexpected reason, in the system log: Space once did nothing while
/// the menu's Quick Look worked (2026-10-18). Typing in a field isn't logged.
///
///   log show --last 2h --info --predicate 'subsystem == "com.banastas.blit" && category == "keys"'
enum KeyLog {
    private static let logger = Logger(subsystem: "com.banastas.blit", category: "keys")

    /// Logs why `key` (Space only) was left alone; returns false (not handled).
    @MainActor static func ignored(_ key: UInt16, _ reason: String) -> Bool {
        if key == 49 { logger.notice("Space ignored: \(reason, privacy: .public)") }
        return false
    }
}
