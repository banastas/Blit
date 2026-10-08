// A record of renames in place (PRD R2.12) in the system log, for the name
// field that closed on its own before any typing (seen on the NAS, fixed in
// 0.2.44; seen again on local volumes during a transfer, never reproduced in
// a test copy). Each start and end, and whatever ends one or takes the
// keyboard while the field is up, with the AppKit and SwiftUI calls that led
// there. No file names: only what happened, and where in the list.
//
//   log show --last 2h --info --predicate 'subsystem == "com.banastas.blit" && category == "rename"'

import Foundation
import os

enum RenameLog {
    private static let logger = Logger(subsystem: "com.banastas.blit", category: "rename")

    /// Logs `event`. `name` (a file name) goes only to a test copy's trail;
    /// `callers` adds the calls that led here.
    @MainActor static func note(_ event: String, name: String? = nil, callers: Bool = false) {
        let stack = callers ? " · " + Self.callers() : ""
        logger.notice("\(event, privacy: .public)\(stack, privacy: .public)")
        #if DEBUG
        UITestHarness.renameTrail.append(event + (name.map { " " + $0 } ?? "") + stack)
        #endif
    }

    /// The calling frames, short: Blit's own, AppKit's and SwiftUI's.
    static func callers(_ count: Int = 26) -> String {
        Thread.callStackSymbols.dropFirst(2).compactMap { line -> String? in
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count > 3 else { return nil }
            let module = String(parts[1])
            guard module == "Blit" || module.hasPrefix("AppKit") || module.hasPrefix("SwiftUI") else { return nil }
            return String(parts[3...].joined(separator: " ").prefix(90))
        }.prefix(count).joined(separator: " < ")
    }
}
