// Emptying the Trash, to get space back (deleted files keep their space until
// then). Each drive other than the startup disk keeps its own Trash at
// /Volumes/<drive>/.Trashes/<uid>, which Blit empties directly: that drive
// only, no permission needed. The Mac's own Trash (and every drive's at once)
// is emptied by Finder over Apple Events, as Finder › Empty Trash does.
// Every empty asks first: it's the one permanent action in Blit.

import AppKit
import Foundation

@MainActor
enum TrashService {
    /// What's in a Trash: top-level items and their allocated bytes.
    struct Contents: Sendable, Equatable {
        var items: Int
        var bytes: Int64
        var isEmpty: Bool { items == 0 }
    }

    /// The Trash folder for the drive holding `url`, or nil for the startup
    /// disk (its Trash is ~/.Trash, reached only through Finder) and network
    /// shares (SMB deletes don't go to a Trash here).
    nonisolated static func volumeTrash(containing url: URL) -> URL? {
        let values = try? url.resourceValues(forKeys: [.volumeURLKey, .volumeIsRootFileSystemKey, .volumeIsLocalKey])
        guard let volume = values?.volume, values?.volumeIsRootFileSystem != true, values?.volumeIsLocal != false,
              volume.path != "/" else { return nil }
        return volume.appendingPathComponent(".Trashes").appendingPathComponent(String(getuid()))
    }

    /// The drive's name, for messages ("SSD").
    nonisolated static func volumeName(containing url: URL) -> String {
        (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName ?? url.lastPathComponent
    }

    /// Counts a Trash folder (off the main thread: it walks every file).
    nonisolated static func contents(of trash: URL) async -> Contents {
        await Task.detached {
            let fm = FileManager.default
            guard let top = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else {
                return Contents(items: 0, bytes: 0)
            }
            var bytes: Int64 = 0
            let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey]
            for item in top {
                let values = try? item.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    let walker = fm.enumerator(at: item, includingPropertiesForKeys: keys)
                    while let file = walker?.nextObject() as? URL {
                        bytes += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
                    }
                } else {
                    bytes += Int64(values?.totalFileAllocatedSize ?? 0)
                }
            }
            // Hidden bookkeeping files (.DS_Store) take no part in the count.
            return Contents(items: top.filter { !$0.lastPathComponent.hasPrefix(".") }.count, bytes: bytes)
        }.value
    }

    /// Permanently removes everything in a drive's Trash folder. Returns the
    /// items that couldn't be removed, with why.
    nonisolated static func erase(_ trash: URL) async -> [String] {
        await Task.detached {
            let fm = FileManager.default
            guard let top = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else { return [] }
            var problems: [String] = []
            for item in top {
                do { try fm.removeItem(at: item) } catch { problems.append("\(item.lastPathComponent): \((error as NSError).localizedDescription)") }
            }
            return problems
        }.value
    }

    /// Finder's own empty-trash sound: an instant empty never reaches the strip.
    static func playEmptySound() {
        #if DEBUG
        if testAnswer != nil { return }
        #endif
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/empty trash.aif"
        NSSound(contentsOfFile: path, byReference: true)?.play()
    }

    #if DEBUG
    /// Test copies answer the confirmation themselves (true: empty).
    static var testAnswer: Bool?
    #endif

    /// Asks before erasing. `what` names the Trash ("the Trash on “SSD”").
    static func confirm(_ what: String, _ contents: Contents?) -> Bool {
        #if DEBUG
        if let testAnswer { return testAnswer }
        #endif
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Permanently erase the items in \(what)?"
        var detail = "You can't undo this."
        if let contents {
            let size = contents.bytes.formatted(.byteCount(style: .file))
            detail = "\(contents.items) item\(contents.items == 1 ? "" : "s"), \(size). " + detail
        }
        alert.informativeText = detail
        alert.addButton(withTitle: "Empty Trash").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Empties Finder's Trash (every drive). Returns a problem, or nil.
    static func emptyFinderTrash() async -> String? {
        let result = await runFinder("tell application \"Finder\" to empty trash")
        guard let error = result.error else { return nil }
        if error.code == -1743 {
            return "Blit isn't allowed to control Finder. Allow it in System Settings › Privacy & Security › Automation, then try again."
        }
        return "Couldn't empty the Trash: \(error.message)"
    }

    /// Items in Finder's Trash (all drives), or nil if Finder can't be asked.
    static func finderTrashCount() async -> Int? {
        let result = await runFinder("tell application \"Finder\" to count items of trash")
        return result.error == nil ? result.value.flatMap { Int($0) } : nil
    }

    private struct ScriptResult: Sendable {
        var value: String?
        var error: (code: Int, message: String)?
    }

    /// Runs AppleScript off the main thread (Finder can take a while).
    private static func runFinder(_ source: String) async -> ScriptResult {
        await Task.detached {
            var info: NSDictionary?
            guard let script = NSAppleScript(source: source) else { return ScriptResult(error: (0, "bad script")) }
            let output = script.executeAndReturnError(&info)
            if let info {
                let code = (info[NSAppleScript.errorNumber] as? Int) ?? 0
                let message = (info[NSAppleScript.errorMessage] as? String) ?? "error \(code)"
                return ScriptResult(error: (code, message))
            }
            return ScriptResult(value: output.stringValue)
        }.value
    }
}

// MARK: - In the strip

extension TransferManager {
    /// Right-click a drive › Empty Trash on “SSD”…: that drive's Trash only,
    /// shown in the strip like any file operation.
    /// Returns what happened, for tests.
    @discardableResult
    func emptyTrash(onDriveContaining url: URL) async -> String {
        let name = TrashService.volumeName(containing: url)
        guard let trash = TrashService.volumeTrash(containing: url) else {
            notice("“\(name)” has no Trash of its own. Use Blit › Empty Trash… instead.", action: "EMPTY TRASH")
            return "no trash"
        }
        let contents = await TrashService.contents(of: trash)
        // Nothing to erase isn't a problem: a beep, as for any action with nothing to do.
        guard !contents.isEmpty else {
            NSSound.beep()
            return "already empty"
        }
        guard TrashService.confirm("the Trash on “\(name)”", contents) else { return "cancelled" }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: trash.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        let job = beginOperation("EMPTYING", done: "EMPTIED", items: names, destination: "Trash on \(name)", link: "LOCAL")
        job.totalBytes = contents.bytes
        let problems = await TrashService.erase(trash)
        job.filesFinished = names.count - problems.count
        job.failures = problems
        job.note(problems.isEmpty ? "✓ \(TransferJob.bytes(contents.bytes)) FREED ON \(name.uppercased())"
                                  : "✕ \(problems.count) NOT ERASED", failure: !problems.isEmpty)
        finishOperation(job)
        guard problems.isEmpty else { return "\(problems.count) not erased" }
        TrashService.playEmptySound()
        return "emptied"
    }

    /// Blit › Empty Trash…: every Trash, through Finder.
    func emptyAllTrash() async {
        let count = await TrashService.finderTrashCount()
        if count == 0 {
            NSSound.beep()
            return
        }
        let what = count.map { "the Trash (\($0) item\($0 == 1 ? "" : "s"))" } ?? "the Trash"
        guard TrashService.confirm(what, nil) else { return }
        let job = beginOperation("EMPTYING", done: "EMPTIED", items: ["Trash"], destination: "every drive", link: "FINDER")
        if let problem = await TrashService.emptyFinderTrash() {
            job.failures = [problem]
        } else {
            job.filesFinished = 1
        }
        finishOperation(job)
    }
}
