// New since your last visit (PRD R2.21): the names each folder listed when it
// was last left, so items that appeared since show a mark. Names, not dates:
// a downloaded file keeps its server's modification time, so a date compared
// with the last visit would call a fresh download old. Kept for the folders
// visited most recently, in Application Support (a debug test copy keeps them
// in memory only).

import Foundation

@MainActor
enum FolderVisits {
    private struct Visit: Codable {
        var location: BrowseLocation
        var left: Date
        var names: [String]
    }

    /// Folders kept, and names in all of them together (the oldest visits go first).
    private static let folderLimit = 100
    private static let nameLimit = 60_000

    private static var visits: [String: Visit] = [:]
    private static var loaded = false
    private static var saving = false

    private static var file: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Blit/folder-visits.json")
    }

    /// Reads the saved visits, once: at once, as the first folder shown at
    /// launch needs them (a small file on the startup disk).
    private static func load() {
        guard !loaded else { return }
        loaded = true
        guard !TransferManager.isIsolated, let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([Visit].self, from: data) else { return }
        for visit in saved { visits[key(visit.location)] = visit }
    }

    /// The names `location` listed when it was last left; nil if it never was.
    static func seen(_ location: BrowseLocation) -> Set<String>? {
        load()
        return visits[key(location)].map { Set($0.names) }
    }

    /// `location` is being left, listing `names`.
    static func left(_ location: BrowseLocation, names: [String]) {
        load()
        visits[key(location)] = Visit(location: location, left: Date(), names: names)
        trim()
        save()
    }

    /// Writes what's kept now (on quit, where a later write wouldn't happen).
    static func saveNow() {
        guard !TransferManager.isIsolated, let data = try? JSONEncoder().encode(Array(visits.values)) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    private static func save() {
        guard !TransferManager.isIsolated, !saving else { return }
        saving = true
        // A moment later, once a burst of moves between folders is over.
        Task {
            try? await Task.sleep(for: .seconds(2))
            saving = false
            guard let data = try? JSONEncoder().encode(Array(visits.values)) else { return }
            let file = file
            await Task.detached {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }.value
        }
    }

    private static func trim() {
        var oldestFirst = visits.values.sorted { $0.left < $1.left }
        var names = oldestFirst.reduce(0) { $0 + $1.names.count }
        while !oldestFirst.isEmpty, oldestFirst.count > folderLimit || names > nameLimit {
            let oldest = oldestFirst.removeFirst()
            names -= oldest.names.count
            visits[key(oldest.location)] = nil
        }
    }

    private static func key(_ location: BrowseLocation) -> String {
        switch location {
        case .local(let url): "local:" + url.lexicalPath
        case .remote(let server, let path): "remote:\(server.uuidString):" + Data(path).base64EncodedString()
        }
    }
}
