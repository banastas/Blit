// The file list's Status column (PRD R2.6): where a row stands in a transfer
// still in the strip (queued, transferring, verifying, done, failed). Rows
// match as a transfer's source (the seedbox folder dragged from) or at its
// destination (including the `.blitpart` of a file on its way).

import BlitSFTP
import Foundation

struct FileStatus: Equatable {
    var text: String
    /// Drawn as a pixel glyph before the text (✓ ✕ ▲ ▼ ‖); nil for none, "=" as text.
    var glyph: Character?
    var isFailure = false
    var help: String
}

extension TransferManager {
    /// The row's status in the newest transfer it's part of, if any.
    func status(for item: FileItem) -> FileStatus? {
        for job in jobs.reversed() where !job.isOperation && job.notice == nil {
            guard let relative = job.relativePath(of: item.location) else { continue }
            if let status = job.fileStatus(relative, isDirectory: item.isDirectory) { return status }
        }
        return nil
    }
}

extension TransferJob {
    /// `location` as one of this job's relative paths ("Pack/a.mkv"): under its
    /// destination, or under one of its sources (named by the source's own name).
    func relativePath(of location: BrowseLocation) -> String? {
        if let url = location.localURL {
            let path = url.standardizedFileURL.path
            let root = destination.standardizedFileURL.path
            if path.hasPrefix(root + "/") {
                var relative = String(path.dropFirst(root.count + 1))
                if relative.hasSuffix(".blitpart") { relative.removeLast(".blitpart".count) }
                return relative
            }
        }
        for source in sources {
            switch (source, location) {
            case (.local(let s), .local(let l)):
                let sp = s.standardizedFileURL.path, lp = l.standardizedFileURL.path
                if lp == sp { return s.lastPathComponent }
                if lp.hasPrefix(sp + "/") { return s.lastPathComponent + "/" + lp.dropFirst(sp.count + 1) }
            case (.remote(let sID, let sBytes), .remote(let lID, let lBytes)) where sID == lID && !sBytes.isEmpty:
                let name = source.lastComponent
                if lBytes == sBytes { return name }
                if lBytes.count > sBytes.count + 1, lBytes.starts(with: sBytes), lBytes[sBytes.count] == UInt8(ascii: "/") {
                    return name + "/" + String(decoding: lBytes[(sBytes.count + 1)...], as: UTF8.self)
                }
            default:
                break
            }
        }
        return nil
    }

    func fileStatus(_ relative: String, isDirectory: Bool) -> FileStatus? {
        isDirectory ? folderStatus(relative) : fileOnlyStatus(relative)
    }

    private var isWaiting: Bool {
        switch status {
        case .queued, .preparing, .waiting, .waitingForSpace: true
        default: false
        }
    }

    private func fileOnlyStatus(_ relative: String) -> FileStatus? {
        if let method = outcomes[relative] ?? (completedPaths.contains(relative) ? "done" : nil) {
            return Self.done(method)
        }
        if let failure = failures.first(where: { $0.hasPrefix(relative + ":") }) {
            return FileStatus(text: "failed", glyph: "✕", isFailure: true, help: failure)
        }
        if verifying[relative] != nil {
            let fraction = hashSizes[relative].flatMap { size in hashed[relative].map { Double($0) / Double(max(size, 1)) } }
            return FileStatus(text: fraction.map { "verifying \(Int(($0 * 100).rounded(.down)))%" } ?? "verifying",
                              glyph: nil, help: "All bytes are in; checking the SHA-256")
        }
        if inFlight.contains(relative) {
            return FileStatus(text: "transferring", glyph: Character(directionGlyph), help: "Being transferred now")
        }
        if status == .paused { return FileStatus(text: "paused", glyph: "‖", help: "The transfer is paused") }
        if isActive || isWaiting { return FileStatus(text: "queued", glyph: nil, help: "Waiting its turn in “\(title)”") }
        return nil
    }

    private func folderStatus(_ relative: String) -> FileStatus? {
        let prefix = relative + "/"
        let failed = failures.filter { $0.hasPrefix(prefix) }.count
        let done = completedPaths.filter { $0.hasPrefix(prefix) }.count
        // A dropped folder is the whole job: show its progress.
        let isWholeJob = sources.count == 1 && !relative.contains("/")
        if status == .paused { return FileStatus(text: "paused", glyph: "‖", help: "The transfer is paused") }
        if isActive, status == .running {
            if isWholeJob {
                return FileStatus(text: "\(Int((progress * 100).rounded(.down)))%", glyph: Character(directionGlyph),
                                  help: "\(filesFinished) of \(fileCount) files done")
            }
            let busy = inFlight.contains { $0.hasPrefix(prefix) } || verifying.keys.contains { $0.hasPrefix(prefix) }
            if busy || done > 0 { return FileStatus(text: "\(done) done", glyph: Character(directionGlyph), help: "\(done) files done so far") }
            return FileStatus(text: "queued", glyph: nil, help: "Waiting its turn in “\(title)”")
        }
        if isWaiting { return FileStatus(text: "queued", glyph: nil, help: "Waiting its turn in “\(title)”") }
        if failed > 0 {
            return FileStatus(text: "\(failed) failed", glyph: "✕", isFailure: true,
                              help: failures.filter { $0.hasPrefix(prefix) }.joined(separator: "\n"))
        }
        if done > 0 || (isWholeJob && status == .finished) {
            return FileStatus(text: "done", glyph: "✓", help: isWholeJob ? "\(filesFinished) of \(fileCount) files done" : "\(done) files done")
        }
        return nil
    }

    private static func done(_ method: String) -> FileStatus {
        switch method {
        case "server-sha256": FileStatus(text: "verified", glyph: "✓", help: "SHA-256 matched the server's")
        case "nas-sha256": FileStatus(text: "verified", glyph: "✓", help: "SHA-256 matched on the NAS")
        case "present-sha256": FileStatus(text: "verified", glyph: "✓", help: "Already there; SHA-256 matched")
        case "read-back": FileStatus(text: "verified", glyph: "✓", help: "SHA-256 matched a read-back of the copy")
        case "cloned": FileStatus(text: "cloned", glyph: "✓", help: "APFS clone on the same volume")
        case "size-only": FileStatus(text: "size only", glyph: "=", help: "Sizes matched; the server couldn't hash it")
        case "verify-off": FileStatus(text: "size only", glyph: "=", help: "Sizes matched; SHA-256 verification is off (Settings › Verify files)")
        case "already-present": FileStatus(text: "already there", glyph: "=", help: "Already at the destination (same size)")
        default: FileStatus(text: "done", glyph: "✓", help: "Transferred (not verified)")
        }
    }
}
