// Missing episodes (PRD R5.5): when episodes arrive, a quiet line in their
// notification if their season has a hole: "S02E04 isn't here, on the NAS or
// on the seedbox". Said only when Blit is sure, never as a guess:
// - only S01E05-style names (double episodes, E04E05, E04-E05 or E04-05,
//   count as both);
// - only a hole between episodes that are there (a season's end is unknown),
//   of at most three (more looks deliberate);
// - only once it has looked everywhere the episode could be: the folder it
//   landed in, the NAS folder Blit knows holds that season (from where the
//   season was filed before, R2.23), the seedbox (its folder, and everything
//   in qBittorrent's records), and Blit's own queue. If any of them can't be
//   read in time, or Blit doesn't know the season's NAS folder, it says nothing.

import Foundation

/// What an S01E05-style name says.
struct EpisodeName: Equatable {
    var show: String
    var season: Int
    var episodes: [Int]

    nonisolated(unsafe) private static let pattern =
        /(?i)^(.*?)[\s._\-]*S(\d{1,2})[\s._\-]?E(\d{1,3})((?:[\s._]?-?[\s._]?E\d{1,3}|-\d{1,3}(?=[\s._\-\[(]|$))*)/
    nonisolated(unsafe) private static let more = /(?i)(-)?[\s._]?E?(\d{1,3})/

    /// A video file's name, or a folder's (an episode in a folder of its own).
    init?(_ name: String, isFolder: Bool) {
        var base = name
        if !isFolder {
            guard ArrivalNotifications.videoExtensions.contains((name as NSString).pathExtension.lowercased()) else { return nil }
            base = (name as NSString).deletingPathExtension
        }
        guard let match = base.firstMatch(of: Self.pattern), let show = ReleaseName.normalized(String(match.1)),
              let season = Int(match.2), let first = Int(match.3) else { return nil }
        var episodes = [first]
        for part in String(match.4).matches(of: Self.more) {
            guard let number = Int(part.2), let last = episodes.last, number > last, number - last <= 10 else { continue }
            // "-E06" or "-06" after E04 is a range; "E05" after E04 is one more.
            episodes += part.1 != nil ? Array((last + 1)...number) : [number]
        }
        self.show = show
        self.season = season
        self.episodes = episodes
    }
}

@MainActor
enum MissingEpisodes {
    /// Shows the user said to stop checking (normalized names).
    static var ignored: Set<String> {
        get { TransferManager.isIsolated ? isolatedIgnored : Set(UserDefaults.standard.stringArray(forKey: "missingEpisodesIgnored") ?? []) }
        set {
            // A test copy shares the user's settings: it keeps its own list.
            if TransferManager.isIsolated { isolatedIgnored = newValue } else { UserDefaults.standard.set(newValue.sorted(), forKey: "missingEpisodesIgnored") }
        }
    }
    private static var isolatedIgnored: Set<String> = []

    /// The holes most worth saying (at most three episodes), between the
    /// lowest and highest episode there; empty when there are none or more.
    nonisolated static func holes(in episodes: Set<Int>) -> [Int] {
        let present = episodes.filter { $0 > 0 }
        guard let low = present.min(), let high = present.max(), high - low >= 2 else { return [] }
        let missing = (low...high).filter { !present.contains($0) }
        return missing.count <= 3 ? missing : []
    }

    /// "S02E04" / "S02E04 and E06" / "S02E04, E06 and E07".
    nonisolated static func label(season: Int, _ episodes: [Int]) -> String {
        let codes = episodes.enumerated().map { index, episode in
            (index == 0 ? String(format: "S%02d", season) : "") + String(format: "E%02d", episode)
        }
        return codes.count == 1 ? codes[0] : codes.dropLast().joined(separator: ", ") + " and " + codes.last!
    }

    /// Every episode named in `names` (each with whether it's a folder), by show and season.
    nonisolated static func episodes(in names: [(String, Bool)]) -> [String: Set<Int>] {
        var found: [String: Set<Int>] = [:]
        for (name, isFolder) in names {
            guard let episode = EpisodeName(name, isFolder: isFolder) else { continue }
            found[key(episode.show, episode.season), default: []].formUnion(episode.episodes)
        }
        return found
    }

    nonisolated static func key(_ show: String, _ season: Int) -> String { "\(show)|\(season)" }

    /// One show's name the start of the other's ("show name", "show name us",
    /// "doctor who 2005"): for whether an episode is there, it counts.
    nonisolated static func sameShow(_ a: String, _ b: String) -> Bool {
        a == b || a.hasPrefix(b + " ") || b.hasPrefix(a + " ")
    }

    /// `show`'s episodes of `season` among `names`; nil when a video that
    /// may be one can't be read as S01E05 (another naming: Blit can't be
    /// sure what's there). `whole`: every video counts (a season folder).
    nonisolated static func scan(_ names: [(String, Bool)], show: String, season: Int, whole: Bool) -> Set<Int>? {
        var found: Set<Int> = []
        for (name, isFolder) in names {
            if let episode = EpisodeName(name, isFolder: isFolder) {
                if episode.season == season, sameShow(episode.show, show) { found.formUnion(episode.episodes) }
                continue
            }
            guard !isFolder, ArrivalNotifications.videoExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            if whole { return nil }
            let base = ReleaseName.normalized((name as NSString).deletingPathExtension) ?? ""
            if sameShow(base, show) || base.hasPrefix(show + " ") { return nil }
        }
        return found
    }

    /// Names in a local folder and in its folders, two levels down; nil if it
    /// can't be read in `seconds` (an unreachable share).
    nonisolated static func localNames(_ folder: URL, within seconds: Double = 3) async -> [(String, Bool)]? {
        await withTaskGroup(of: [(String, Bool)]?.self) { group in
            group.addTask {
                guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
                var names: [(String, Bool)] = []
                let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                                                            options: [.skipsHiddenFiles, .skipsPackageDescendants])
                while let url = walker?.nextObject() as? URL {
                    if walker?.level ?? 0 > 2 { walker?.skipDescendants(); continue }
                    names.append((url.lastPathComponent, (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false))
                }
                return names
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// The line for a finished download's notification, if what arrived
    /// leaves a hole in its season that's nowhere else; with the shows it names.
    static func note(for job: TransferJob, transfers: TransferManager?) async -> (text: String, shows: [String])? {
        guard case .download = job.kind else { return nil }
        // What arrived: the items themselves and what's in them.
        var arrivedNames: [(String, Bool)] = []
        for name in Set(job.sources.map(\.lastComponent)) {
            let url = job.destination.appendingPathComponent(name)
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { continue }
            arrivedNames.append((name, isFolder.boolValue))
            if isFolder.boolValue { arrivedNames += await localNames(url) ?? [] }
        }
        let arrived = episodes(in: arrivedNames)
        guard !arrived.isEmpty, let landed = await localNames(job.destination) else { return nil }
        var seedboxRead = false
        var seedbox: [(String, Bool)]?
        var lines: [String] = []
        var shows: [String] = []
        for key in arrived.keys.sorted() {
            let parts = key.split(separator: "|")
            guard parts.count == 2, let season = Int(parts[1]) else { continue }
            let show = String(parts[0])
            guard !ignored.contains(show) else { continue }
            // Every place it could be, each read in full and in a naming Blit
            // understands, or nothing is said.
            guard var present = scan(landed, show: show, season: season, whole: false),
                  let nas = DestinationMemory.shared.folder(forShow: show, season: season)?.localURL,
                  let nasNames = await localNames(nas),
                  let onNAS = scan(nasNames, show: show, season: season, whole: true) else { continue }
            present.formUnion(onNAS)
            if !seedboxRead {
                seedboxRead = true
                seedbox = await seedboxNames(job)
            }
            guard let seedboxNames = seedbox, let onSeedbox = scan(seedboxNames, show: show, season: season, whole: false) else { continue }
            present.formUnion(onSeedbox)
            let queued = (transfers?.jobs ?? []).filter { $0 !== job && $0.status != .finished }.flatMap(\.sources).map { ($0.lastComponent, true) }
            present.formUnion(scan(queued, show: show, season: season, whole: false) ?? [])
            let missing = holes(in: present)
            guard !missing.isEmpty else { continue }
            lines.append(label(season: season, missing) + (missing.count == 1 ? " isn't" : " aren't") + " here, on the NAS or on the seedbox.")
            shows.append(show)
        }
        return lines.isEmpty ? nil : (lines.joined(separator: " "), shows)
    }

    /// The names on the seedbox the job came from: its folder's, and every
    /// torrent's in qBittorrent's records there. nil if they can't be read
    /// within eight seconds.
    private static func seedboxNames(_ job: TransferJob) async -> [(String, Bool)]? {
        guard let folder = job.sources.first?.parent else { return nil }
        enum Read: Sendable { case names([(String, Bool)]), nothing }
        let read = await withTaskGroup(of: Read.self) { group in
            group.addTask { await seedboxListing(folder).map(Read.names) ?? .nothing }
            group.addTask {
                try? await Task.sleep(for: .seconds(8))
                return .nothing
            }
            let first = await group.next() ?? .nothing
            group.cancelAll()
            return first
        }
        if case .names(let names) = read { return names }
        return nil
    }

    private static func seedboxListing(_ folder: BrowseLocation) async -> [(String, Bool)]? {
        guard let library = TorrentLibrary.shared, let listed = await library.names(in: folder) else { return nil }
        var names = listed
        // No records (another client): the folder alone says what's there.
        if let records = await library.recordsFolder(for: folder) {
            guard let torrents = await library.torrents(in: records, on: folder) else { return nil }
            names += torrents.flatMap { torrent in torrent.names.map { ($0, true) } }
        }
        return names
    }
}
