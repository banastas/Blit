// Which local files Blit has copied and verified by SHA-256 (PRD R4.4), from
// the transfer log, for the pixel ✓ in the file list. A file counts only
// while its size still matches what was verified.

import Foundation
import Observation

@MainActor
@Observable
final class VerifiedIndex {
    static let shared = VerifiedIndex()

    struct Entry: Equatable {
        let size: UInt64
        /// "server-sha256", "nas-sha256" or "read-back".
        let method: String
        let time: Date

        var summary: String {
            let how = switch method {
            case "server-sha256": "SHA-256 matched the server's"
            case "nas-sha256": "SHA-256 matched the NAS's"
            default: "SHA-256 matched on read-back"
            }
            return "Verified by Blit · \(how) · \(time.formatted(date: .abbreviated, time: .shortened))"
        }
    }

    private static let strongMethods: Set<String> = ["server-sha256", "nas-sha256", "read-back"]
    private(set) var entries: [String: Entry] = [:]
    @ObservationIgnored private var loaded = false

    /// Reads the transfer log once, off the main thread.
    func load() {
        guard !loaded else { return }
        loaded = true
        let url = TransferLog.url
        Task {
            let records = await Task.detached { TransferLog.readRecords(at: url) }.value
            for record in records { apply(record) }
        }
    }

    func record(_ record: TransferRecord) { apply(record) }

    private func apply(_ record: TransferRecord) {
        let key = URL(fileURLWithPath: record.destination).standardizedFileURL.path
        switch (record.result, record.verification) {
        case ("ok", let method) where Self.strongMethods.contains(method):
            entries[key] = Entry(size: record.size, method: method, time: record.time)
        case ("ok", "already-present"), ("ok", "cloned"):
            break   // the same bytes as before: keep whatever was known
        default:
            // Rewritten without a hash (size only, unverified) or failed: the old
            // badge no longer describes these bytes.
            entries[key] = nil
        }
    }

    func entry(for url: URL, size: Int64) -> Entry? {
        guard let entry = entries[url.standardizedFileURL.path], Int64(entry.size) == size else { return nil }
        return entry
    }

    /// Drops badges for an item Blit deleted or trashed (and anything inside it).
    func removed(_ url: URL) {
        let path = url.standardizedFileURL.path
        for key in entries.keys where key == path || key.hasPrefix(path + "/") { entries[key] = nil }
    }

    /// Keeps badges when Blit renames or moves items on a volume (this session).
    func moved(from old: URL, to new: URL) {
        let from = old.standardizedFileURL.path, to = new.standardizedFileURL.path
        for (key, entry) in entries where key == from || key.hasPrefix(from + "/") {
            entries[key] = nil
            entries[to + key.dropFirst(from.count)] = entry
        }
    }
}
