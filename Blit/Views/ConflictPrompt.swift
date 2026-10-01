// Replace, Keep Both, Skip or Stop, as in Finder, when a move or copy would
// land on a file that already exists (instead of failing it later). Asked
// once per drop, paste or Copy To / Move To, for all its conflicts.

import AppKit
import BlitRemote
import BlitSFTP

@MainActor
enum ConflictPrompt {
    enum Choice { case replace, keepBoth, skip, stop }

    struct Conflict: Sendable {
        let source: BrowseLocation
        let name: String
        let existing: URL
        /// "Existing: 71.2 GB, modified … / New: …" (read with the check, off the main thread).
        let detail: String?
    }

    /// Sources whose name is already taken by a file (not a folder: folders
    /// merge) in `folder`. Checked off the main thread (the folder may be on a NAS).
    static func conflicts(_ sources: [BrowseLocation], in folder: URL) async -> [Conflict] {
        let named = sources.map { ($0, name(for: $0)) }
        return await Task.detached {
            named.compactMap { source, name -> Conflict? in
                let target = folder.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
                      !isDirectory.boolValue else { return nil }
                if let url = source.localURL, url.lexicalPath == target.lexicalPath { return nil }
                return Conflict(source: source, name: name, existing: target, detail: describe(existing: target, source: source))
            }
        }.value
    }

    /// The name a source gets at its destination (server names made safe, as the engine does).
    static func name(for source: BrowseLocation) -> String {
        switch source {
        case .local(let url): return url.lastPathComponent
        case .remote(_, let bytes):
            let last = bytes.split(separator: UInt8(ascii: "/")).last.map(Array.init) ?? bytes
            return TransferPlan.localName(RemotePath(bytes: last))
        }
    }

    #if DEBUG
    /// Tests answer instead of the dialog.
    static var testAnswer: Choice?
    static var lastAsked: (count: Int, move: Bool)?
    #endif

    /// Asks what to do (a sheet on the front window when there is one).
    static func ask(_ conflicts: [Conflict], folderName: String, move: Bool) async -> Choice {
        #if DEBUG
        if let testAnswer {
            lastAsked = (conflicts.count, move)
            return testAnswer
        }
        #endif
        let alert = NSAlert()
        alert.alertStyle = .warning
        let verb = move ? "moving" : "copying"
        if conflicts.count == 1, let only = conflicts.first {
            alert.messageText = "“\(only.name)” already exists in “\(folderName)”."
            var info = "Do you want to replace it with the one you're \(verb)?"
            if let detail = only.detail { info += "\n\n" + detail }
            alert.informativeText = info
        } else {
            alert.messageText = "\(conflicts.count) items already exist in “\(folderName)”."
            let names = conflicts.prefix(4).map { "“\($0.name)”" }.joined(separator: ", ") + (conflicts.count > 4 ? "…" : "")
            alert.informativeText = "Do you want to replace them with the ones you're \(verb)? \(names)"
        }
        alert.informativeText += "\n\nA replaced file is only overwritten once the new one has arrived and been verified; on the same drive it goes to the Trash."
        alert.addButton(withTitle: "Replace")
        alert.addButton(withTitle: "Keep Both")
        alert.addButton(withTitle: "Skip")
        let stop = alert.addButton(withTitle: "Stop")
        stop.keyEquivalent = "\u{1b}"
        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        switch response {
        case .alertFirstButtonReturn: return .replace
        case .alertSecondButtonReturn: return .keepBoth
        case .alertThirdButtonReturn: return .skip
        default: return .stop
        }
    }

    /// "Existing: 71.2 GB, modified … / New: 71.62 GB, modified …" (the new side for local sources).
    nonisolated private static func describe(existing: URL, source: BrowseLocation) -> String? {
        func describe(_ url: URL) -> String? {
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = (a[.size] as? NSNumber)?.int64Value, let date = a[.modificationDate] as? Date else { return nil }
            return "\(size.formatted(.byteCount(style: .file))), modified \(date.formatted(date: .abbreviated, time: .shortened))"
        }
        guard let old = describe(existing) else { return nil }
        if let url = source.localURL, let new = describe(url) { return "Existing: \(old)\nNew: \(new)" }
        return "Existing: \(old)"
    }
}
