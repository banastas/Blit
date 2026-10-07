// Suggested destinations (PRD R2.23): where items like these went before.
// Release names are read for a show (South.Park.S29E02 → "south park",
// season 29) or a movie (a year and no episode, by resolution, so 4K and
// 1080p libraries stay apart). Each time items from this Mac are moved or
// copied somewhere, the folder is remembered for their key; Move To, Copy To,
// the context menu and File › Move to Suggested Folder (⇧F6) then offer the
// latest folders. A new season gets the next "Season NN" folder beside the
// last one (made at the move, if it isn't there yet); a movie filed in a
// folder of its own ("Title (2019)") teaches that folder's parent.

import Foundation
import Observation
import UniformTypeIdentifiers

/// What a release name says, as far as filing goes.
struct ReleaseName: Equatable {
    enum Key: Hashable, Codable {
        case show(String)
        /// "2160p", "1080p", "720p", "sd", or "any" (movies of every resolution).
        case movie(String)
    }

    var key: Key
    var season: Int?
    var year: Int?

    private static let mediaExtensions: Set<String> = ["mkv", "mk3d", "mp4", "m4v", "avi", "mov", "ts", "m2ts", "webm", "wmv",
                                                       "mpg", "srt", "ass", "ssa", "sub", "idx", "sup", "nfo"]
    // Regexes don't change once made.
    nonisolated(unsafe) private static let episode = /(?i)^(.*?)[\s._\-]*S(\d{1,2})[\s._\-]?E\d{1,3}/
    nonisolated(unsafe) private static let crossEpisode = /(?i)^(.*?)[\s._\-]+(\d{1,2})x\d{2,3}\b/
    nonisolated(unsafe) private static let seasonPack = /(?i)^(.*?)[\s._\-]+(?:S(\d{1,2})|Season[\s._\-]*(\d{1,2}))(?=[\s._\-]|$)/
    nonisolated(unsafe) private static let year = /(?:^|[\s._(\[\-])((?:19|20)\d{2})(?=[\s._)\]\-]|$)/

    init?(_ name: String) {
        var base = name
        let ext = (name as NSString).pathExtension.lowercased()
        if Self.mediaExtensions.contains(ext) {
            base = (name as NSString).deletingPathExtension
        } else if !ext.isEmpty, let type = UTType(filenameExtension: ext), !type.isDynamic {
            return nil   // another kind of file (a photo, an archive); a release folder's last word isn't a type
        }
        if let match = base.firstMatch(of: Self.episode) ?? base.firstMatch(of: Self.crossEpisode),
           let show = Self.normalized(String(match.1)) {
            key = .show(show)
            season = Int(match.2)
            return
        }
        if let match = base.firstMatch(of: Self.seasonPack), let show = Self.normalized(String(match.1)) {
            key = .show(show)
            season = (match.2 ?? match.3).flatMap { Int($0) }
            return
        }
        // A movie: the last year with a title before it.
        guard let found = base.matches(of: Self.year).last(where: { $0.range.lowerBound > base.startIndex }),
              Self.normalized(String(base[..<found.range.lowerBound])) != nil else { return nil }
        year = Int(found.1)
        let lower = base.lowercased()
        let resolution = if lower.contains("2160p") || lower.contains("4k") || lower.contains("uhd") { "2160p" }
            else if lower.contains("1080p") || lower.contains("1080i") { "1080p" }
            else if lower.contains("720p") { "720p" }
            else if lower.contains("480p") || lower.contains("576p") || lower.contains("dvdrip") { "sd" }
            else { "any" }
        key = .movie(resolution)
    }

    /// "South.Park" → "south park"; "Doctor.Who.(2005)" → "doctor who 2005"; nil if nothing's left.
    static func normalized(_ text: String) -> String? {
        let words = text.lowercased().split(whereSeparator: { " ._-()[]".contains($0) })
        return words.isEmpty ? nil : words.joined(separator: " ")
    }

    /// A season folder's name, its prefix, its number's digits: "Season 01" → ("Season ", 1, 2 digits).
    static func seasonFolder(_ name: String) -> (prefix: String, number: Int, digits: Int)? {
        guard let match = name.wholeMatch(of: /(?i)((?:season|staffel|saison|series|s)[\s._\-]*)(\d{1,3})/),
              let number = Int(match.2) else { return nil }
        return (String(match.1), number, match.2.count)
    }
}

@MainActor
@Observable
final class DestinationMemory {
    static let shared = DestinationMemory()

    struct Entry: Codable, Equatable {
        var folder: BrowseLocation
        /// The season of what went there (shows).
        var season: Int?
        var used: Date
    }

    /// A folder offered for some items.
    struct Suggestion: Equatable {
        let folder: BrowseLocation
        /// The folder's name, and where it is ("South Park", or the volume).
        let name: String
        let detail: String?
        /// A season folder worked out from another season's: made at the move
        /// if it isn't there yet (menus don't look at the disk to know).
        let mayBeNew: Bool
        /// Why it's offered, for a help tag.
        let reason: String

        var title: String { detail.map { "\(name) — \($0)" } ?? name }
    }

    /// Folders by key, latest first.
    private var entries: [String: [Entry]] = [:]
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var saving = false
    private static let perKey = 3, keyLimit = 2_000

    private static var file: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Blit/destinations.json")
    }

    private static func id(_ key: ReleaseName.Key) -> String {
        switch key {
        case .show(let name): "show:" + name
        case .movie(let resolution): "movie:" + resolution
        }
    }

    // MARK: Learning

    /// `sources` were moved or copied into `folder` (from Blit: a drop, a
    /// paste, F5/F6, Move To…). Only what comes from this Mac teaches it:
    /// downloads aren't filing.
    func learn(_ sources: [BrowseLocation], into folder: BrowseLocation) {
        load()
        var changed = false
        for source in sources where source.localURL != nil {
            guard source.parent.map({ !FileOperations.same($0, folder) }) ?? true,
                  let release = ReleaseName(source.lastComponent) else { continue }
            var target = folder
            // A movie in a folder of its own ("The Gentlemen (2019)"): the shelf is its parent.
            if case .movie = release.key, let year = release.year, folder.lastComponent.contains(String(year)),
               let parent = folder.parent {
                target = parent
            }
            let entry = Entry(folder: target, season: release.season, used: Date())
            var keys = [Self.id(release.key)]
            if case .movie(let resolution) = release.key, resolution != "any" { keys.append(Self.id(.movie("any"))) }
            for key in keys {
                var list = entries[key] ?? []
                list.removeAll { FileOperations.same($0.folder, target) }
                list.insert(entry, at: 0)
                entries[key] = Array(list.prefix(Self.perKey))
            }
            changed = true
        }
        guard changed else { return }
        trim()
        save()
    }

    // MARK: Suggesting

    /// Up to two folders for `items` (all the same show, or all movies of one
    /// kind): the latest first, never where they are now.
    func suggestions(for items: [FileItem]) -> [Suggestion] {
        guard !items.isEmpty, items.count <= 200 else { return [] }
        load()
        let releases = items.compactMap { ReleaseName($0.name) }
        guard let first = releases.first, releases.allSatisfy({ $0.key == first.key }) else { return [] }
        let seasons = Set(releases.compactMap(\.season))
        let season = seasons.count == 1 ? seasons.first : nil
        var candidates = entries[Self.id(first.key)] ?? []
        if case .movie(let resolution) = first.key, resolution != "any" {
            candidates += (entries[Self.id(.movie("any"))] ?? []).filter { entry in !candidates.contains { $0.folder == entry.folder } }
        }
        // The folder this very season went to comes before one worked out from another season's.
        if let season {
            candidates = candidates.filter { $0.season == season } + candidates.filter { $0.season != season }
        }
        let parents = items.compactMap(\.location.parent)
        var result: [Suggestion] = []
        for entry in candidates {
            guard let suggestion = suggestion(from: entry, for: first, season: season) else { continue }
            guard !parents.contains(where: { FileOperations.same($0, suggestion.folder) }),
                  !result.contains(where: { FileOperations.same($0.folder, suggestion.folder) }) else { continue }
            result.append(suggestion)
            if result.count == 2 { break }
        }
        return result
    }

    private func suggestion(from entry: Entry, for release: ReleaseName, season: Int?) -> Suggestion? {
        let what: String = switch release.key {
        case .show(let name): entry.season.map { "\(name.capitalized) season \($0)" } ?? "the last \(name.capitalized) episode"
        case .movie(let resolution): resolution == "any" ? "the last movie" : "the last \(resolution) movie"
        }
        // The next season beside the last one's folder ("Season 28" → "Season 29").
        if let season, let last = entry.season, season != last, entry.folder.localURL != nil,
           let folder = ReleaseName.seasonFolder(entry.folder.lastComponent), folder.number == last,
           let show = entry.folder.parent {
            let number = String(season)
            let name = folder.prefix + String(repeating: "0", count: max(0, folder.digits - number.count)) + number
            return Suggestion(folder: FileOperations.child(of: show, named: name), name: name, detail: show.lastComponent,
                              mayBeNew: true, reason: "Beside “\(entry.folder.lastComponent)”, where \(what) went")
        }
        return Suggestion(folder: entry.folder, name: entry.folder.lastComponent, detail: entry.folder.parent?.lastComponent,
                          mayBeNew: false, reason: "Where \(what) went")
    }

    // MARK: Keeping

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard !TransferManager.isIsolated, let data = try? Data(contentsOf: Self.file),
              let saved = try? JSONDecoder().decode([String: [Entry]].self, from: data) else { return }
        entries = saved
    }

    private func trim() {
        guard entries.count > Self.keyLimit else { return }
        let oldest = entries.sorted { ($0.value.first?.used ?? .distantPast) < ($1.value.first?.used ?? .distantPast) }
        for (key, _) in oldest.prefix(entries.count - Self.keyLimit) { entries[key] = nil }
    }

    private func save() {
        guard !TransferManager.isIsolated, !saving else { return }
        saving = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            saving = false
            guard let data = try? JSONEncoder().encode(entries) else { return }
            let file = Self.file
            await Task.detached {
                try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
            }.value
        }
    }

    #if DEBUG
    /// Starts empty (the tests).
    func reset() { entries = [:] }
    #endif
}
