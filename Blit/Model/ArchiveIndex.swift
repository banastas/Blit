// Find in Archive (PRD R4.6): every file Blit has moved, found by any name it
// had, with where it went last, from the transfer log alone, so it answers
// while the NAS is asleep. A file is followed through the log by its SHA-256
// (a download renamed on this Mac and later copied to the NAS is one file) and
// by path (a record whose source is an earlier record's destination).

import Foundation

/// One file, as the transfer log knows it.
struct ArchiveItem: Identifiable, Sendable {
    let id: Int
    /// Where it went last, and when.
    var location: String
    var time: Date
    var size: UInt64
    /// The best check it had there: "nas-sha256", "server-sha256", "read-back"…
    var verification: String
    /// Every name it had, oldest first.
    var names: [String]
    /// Everywhere it went before, oldest first.
    var earlier: [String]
    /// Its names and its last folder, lowercased with separators as spaces, for search.
    var haystack: String

    var name: String { (location as NSString).lastPathComponent }
    var folder: String { (location as NSString).deletingLastPathComponent }
    var verified: Bool { ["nas-sha256", "server-sha256", "present-sha256", "read-back", "cloned", "already-present"].contains(verification) }
}

enum ArchiveIndex {
    /// Lower case, with dots, dashes, underscores and brackets as spaces:
    /// "Get-Jiro_S01E02.mkv" and "get jiro s01e02" meet.
    static func normalized(_ text: String) -> String {
        let spaced = text.lowercased().map { "._-()[]{}".contains($0) ? " " : $0 }
        return String(spaced).split(separator: " ").joined(separator: " ")
    }

    /// Paths a test copy wrote before test copies had their own log.
    static func isTestPath(_ path: String) -> Bool {
        path.hasPrefix("/var/folders/") || path.hasPrefix("/private/var/") || path.hasPrefix("/tmp/")
            || path.hasPrefix("/Volumes/BlitQueue/") || path.hasPrefix("/Volumes/BlitConflict/")
    }

    /// The files in the log at `url`, newest first. Reads the log: off the main thread.
    static func load(_ url: URL) -> [ArchiveItem] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var items: [ArchiveItem] = []
        var bySHA: [String: Int] = [:]
        var byPath: [String: Int] = [:]
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let record = try? decoder.decode(TransferRecord.self, from: Data(line)), record.result == "ok",
                  !isTestPath(record.destination), !isTestPath(record.source) else { continue }
            let sha = record.sha256.flatMap { $0.isEmpty ? nil : $0 }
            let name = (record.destination as NSString).lastPathComponent
            // A server path ("user@host:files/…") keeps only its file name as a name.
            let sourceName = (record.source as NSString).lastPathComponent
            if let index = sha.flatMap({ bySHA[$0] }) ?? byPath[record.source] {
                var item = items[index]
                if item.location != record.destination { item.earlier.append(item.location) }
                item.location = record.destination
                item.time = record.time
                item.size = record.size
                if record.verification != "none" || !item.verified { item.verification = record.verification }
                for candidate in [sourceName, name] where !item.names.contains(candidate) { item.names.append(candidate) }
                items[index] = item
                if let sha { bySHA[sha] = index }
                byPath[record.destination] = index
            } else {
                let index = items.count
                var names = [sourceName]
                if name != sourceName { names.append(name) }
                items.append(ArchiveItem(id: index, location: record.destination, time: record.time, size: record.size,
                                         verification: record.verification, names: names, earlier: [], haystack: ""))
                if let sha { bySHA[sha] = index }
                byPath[record.destination] = index
            }
        }
        for index in items.indices {
            let item = items[index]
            items[index].haystack = normalized((item.names + [(item.folder as NSString).lastPathComponent,
                                                             ((item.folder as NSString).deletingLastPathComponent as NSString).lastPathComponent])
                .joined(separator: " "))
        }
        return items.sorted { $0.time > $1.time }
    }

    /// The items matching every word of `query` (newest first), at most `limit`.
    static func search(_ query: String, in items: [ArchiveItem], limit: Int = 200) -> [ArchiveItem] {
        let words = normalized(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [] }
        var found: [ArchiveItem] = []
        for item in items where words.allSatisfy({ item.haystack.contains($0) }) {
            found.append(item)
            if found.count == limit { break }
        }
        return found
    }

    /// "Files" for /Volumes/Files/…, "this Mac" for the startup disk.
    static func volumeName(_ path: String) -> String {
        let parts = path.split(separator: "/")
        return parts.count > 1 && parts[0] == "Volumes" ? String(parts[1]) : "this Mac"
    }
}
