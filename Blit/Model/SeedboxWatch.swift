// Watch mode (PRD R5.10): Blit looks in a server folder every few minutes and
// downloads what's new to a folder on this Mac, while it's still in the
// server's cache (2–3× faster than cold). Only server → Mac: what goes on to
// the NAS stays the user's call (they review on the SSD first).
//
// An item is fetched only once it's finished: it wasn't there when watching
// began, nothing in it looks like a partial download (.part, .!qB…), and its
// size and newest modification time haven't changed since the last look and
// are at least two minutes old. (Seedbox clients often make a file its full
// size before a byte arrives, so size alone can't tell.) A fetch is the
// ordinary verified copy, never a move: the server keeps seeding.

import BlitRemote
import BlitSFTP
import Foundation
import Observation

/// A watched folder and where its new items go.
struct WatchRule: Codable, Identifiable, Hashable {
    var id = UUID()
    /// A folder on a server (or, in a test copy, a local stand-in).
    var source: BrowseLocation
    /// A folder on this Mac.
    var destination: String
    var minutes = 2
    var enabled = true
}

/// What a rule has seen.
struct WatchState: Codable, Equatable {
    /// Names done with: there when watching began, fetched, or already at the destination.
    var handled: Set<String> = []
    /// New items not finished yet, as they last looked.
    var pending: [String: WatchSnapshot] = [:]
    var lastCheck: Date?
    var lastFetched: String?
    var problem: String?
    /// qBittorrent's records (BT_backup) for this server, when found, and the
    /// watched folder's full path they name it by; looked for at most daily.
    var records: String?
    var recordsChecked: Date?
    var folderPath: String?
    /// Items never fetched: qBittorrent's incomplete folder, where it's inside the watched one.
    var excluded: Set<String> = []
    /// New items qBittorrent is still downloading, and how far along.
    var downloading: [String: Double] = [:]
}

struct WatchSnapshot: Codable, Equatable {
    var size: Int64
    var newest: Date?
}

/// A top-level item in a watched folder, looked at closely.
struct WatchEntry: Sendable {
    var name: String
    var location: BrowseLocation
    var size: Int64
    var newest: Date?
    var incomplete: Bool
}

@MainActor
@Observable
final class SeedboxWatch {
    /// The app's (menus and Settings reach it here).
    static var shared: SeedboxWatch?

    private(set) var rules: [WatchRule] = []
    private(set) var states: [UUID: WatchState] = [:]
    @ObservationIgnored private var checking: Set<UUID> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private let servers: ServerStore
    @ObservationIgnored private let connections: ConnectionManager
    /// Starts a verified copy of `sources` into a folder (FileOperations.place).
    @ObservationIgnored var fetch: ([BrowseLocation], URL) async -> String?
    /// How old an item's newest change must be before it's fetched.
    @ObservationIgnored var settle: TimeInterval = 120

    nonisolated static let partialSuffixes = [".part", ".!qb", ".!ut", ".!bt", ".crdownload", ".partial", ".tmp", ".download", ".blitpart", ".aria2"]

    /// A name a download client gives a file it's still writing.
    nonisolated static func isPartial(_ path: String) -> Bool { partialSuffixes.contains { path.lowercased().hasSuffix($0) } }

    init(servers: ServerStore, connections: ConnectionManager, fetch: @escaping ([BrowseLocation], URL) async -> String?) {
        self.servers = servers
        self.connections = connections
        self.fetch = fetch
        load()
    }

    private static var file: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Blit/watches.json")
    }

    // MARK: Rules

    func rule(watching source: BrowseLocation) -> WatchRule? { rules.first { $0.source == source } }

    /// Whether any folder on `server` is watched.
    func watches(server id: UUID) -> Bool { rules.contains { $0.enabled && $0.source.serverID == id } }

    /// "Seedbox › completed".
    func title(of rule: WatchRule) -> String {
        let server = rule.source.serverID.flatMap { servers.server($0)?.displayName } ?? "Server"
        let folder = rule.source.lastComponent
        return folder.isEmpty ? server : "\(server) › \(folder)"
    }

    func add(_ rule: WatchRule) {
        rules.removeAll { $0.source == rule.source }
        rules.append(rule)
        states[rule.id] = nil   // the first look takes what's there as seen
        save()
        start()
        Task { await check(rule.id) }
    }

    func remove(_ id: UUID) {
        rules.removeAll { $0.id == id }
        states[id] = nil
        save()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = rules.firstIndex(where: { $0.id == id }), rules[index].enabled != enabled else { return }
        rules[index].enabled = enabled
        // Back on: what arrived meanwhile counts as seen, as when watching began.
        if enabled { states[id] = nil }
        save()
        if enabled { Task { await check(id) } }
    }

    func setMinutes(_ id: UUID, _ minutes: Int) {
        guard let index = rules.firstIndex(where: { $0.id == id }), rules[index].minutes != minutes else { return }
        rules[index].minutes = minutes
        save()
    }

    /// Looks every 15 s for rules that are due.
    func start() {
        guard loop == nil, !rules.isEmpty else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for rule in self.rules where rule.enabled {
                    let last = self.states[rule.id]?.lastCheck ?? .distantPast
                    if Date().timeIntervalSince(last) >= Double(rule.minutes * 60) { Task { await self.check(rule.id) } }
                }
                try? await Task.sleep(for: .seconds(15))
            }
        }
    }

    // MARK: Looking

    /// One look at a rule's folder: new finished items are fetched.
    func check(_ id: UUID) async {
        guard let rule = rules.first(where: { $0.id == id }), rule.enabled, !checking.contains(id) else { return }
        checking.insert(id)
        defer { checking.remove(id) }
        var state = states[id] ?? WatchState()
        let first = states[id] == nil
        state.lastCheck = Date()
        let destination = URL(fileURLWithPath: rule.destination)
        let reachable = await Task.detached { FileManager.default.fileExists(atPath: destination.path) }.value
        guard reachable else {
            state.problem = "“\(destination.lastPathComponent)” isn't available"
            return publish(id, state)
        }
        let items: [String: BrowseLocation]
        do {
            items = try await topLevel(rule.source)
        } catch {
            state.problem = "Couldn't look in the folder: \(FileOperations.describe(error))"
            return publish(id, state)
        }
        state.problem = nil
        let names = Set(items.keys)
        if first {
            // Watching begins: everything there now is old news.
            state.handled = Set(names)
            return publish(id, state)
        }
        // Gone from the server: forgotten (handled stays bounded).
        state.handled.formIntersection(names)
        state.pending = state.pending.filter { names.contains($0.key) }
        state.downloading = state.downloading.filter { names.contains($0.key) }
        let fresh = names.subtracting(state.handled)
        // What qBittorrent says about the new items, where it keeps records here.
        let claims = await torrentClaims(for: fresh, rule: rule, state: &state)
        var ready: [WatchEntry] = []
        for (name, location) in items.sorted(by: { $0.key < $1.key }) where !state.handled.contains(name) {
            if Self.isPartial(name) || state.excluded.contains(name) { continue }
            // Fetched by hand already: nothing to do.
            let there = destination.appendingPathComponent(name)
            if await Task.detached(operation: { FileManager.default.fileExists(atPath: there.path) }).value {
                state.handled.insert(name)
                state.pending[name] = nil
                state.downloading[name] = nil
                continue
            }
            // A torrent of qBittorrent's: finished when it says so, however quiet its files.
            if let torrents = claims[name] {
                if torrents.allSatisfy(\.finished) {
                    state.downloading[name] = nil
                    ready.append(WatchEntry(name: name, location: location, size: 0, newest: nil, incomplete: false))
                } else {
                    state.downloading[name] = torrents.map(\.fraction).min() ?? 0
                    state.pending[name] = nil
                }
                continue
            }
            guard let entry = try? await look(at: name, location) else { continue }
            let snapshot = WatchSnapshot(size: entry.size, newest: entry.newest)
            let settled = entry.newest.map { Date().timeIntervalSince($0) >= settle } ?? true
            if !entry.incomplete, entry.size > 0, settled, state.pending[name] == snapshot {
                ready.append(entry)
            } else {
                state.pending[name] = snapshot
            }
        }
        for entry in ready {
            state.handled.insert(entry.name)
            state.pending[entry.name] = nil
            state.lastFetched = entry.name
        }
        publish(id, state)
        if !ready.isEmpty, let problem = await fetch(ready.map(\.location), destination) {
            states[id]?.problem = problem
        }
    }

    // MARK: qBittorrent's records

    /// For each of `names` that a torrent in qBittorrent's records saves into
    /// the watched folder, those torrents. Empty where there are no records.
    private func torrentClaims(for names: Set<String>, rule: WatchRule, state: inout WatchState) async -> [String: [TorrentRecord]] {
        guard !names.isEmpty, let library = TorrentLibrary.shared else { return [:] }
        // Found once, looked for again daily (qBittorrent may come later).
        if state.records == nil, Date().timeIntervalSince(state.recordsChecked ?? .distantPast) > 86_400 {
            state.recordsChecked = Date()
            state.records = await library.recordsFolder(for: rule.source, recheck: true)
            state.folderPath = await library.absolutePath(rule.source)
            if let records = state.records, let watched = state.folderPath, let settings = await library.settings(for: rule.source, records: records) {
                state.excluded = Self.incompleteFolders(in: settings.text, watched: watched)
            }
        }
        guard let records = state.records, let watched = state.folderPath,
              let torrents = await library.torrents(in: records, on: rule.source) else { return [:] }
        var claims: [String: [TorrentRecord]] = [:]
        for torrent in torrents where torrent.resume.savePath == watched {
            for name in torrent.names.intersection(names) {
                claims[name, default: []].append(TorrentRecord(names: torrent.names, savePath: torrent.resume.savePath,
                                                               finished: torrent.resume.finished, fraction: torrent.resume.fraction))
            }
        }
        return claims
    }

    /// qBittorrent's incomplete folder (Session\TempPath, or Downloads\TempPath
    /// in older versions), by name, if it's directly in the watched folder:
    /// it holds unfinished downloads, so it's never fetched.
    static func incompleteFolders(in settings: String, watched: String) -> Set<String> {
        var names: Set<String> = []
        for line in settings.split(whereSeparator: \.isNewline) {
            for key in ["Session\\TempPath=", "Downloads\\TempPath="] where line.hasPrefix(key) {
                var path = String(line.dropFirst(key.count))
                while path.hasSuffix("/") { path.removeLast() }
                let parent = (path as NSString).deletingLastPathComponent
                if !path.isEmpty, parent == watched { names.insert((path as NSString).lastPathComponent) }
            }
        }
        return names
    }

    private func publish(_ id: UUID, _ state: WatchState) {
        guard rules.contains(where: { $0.id == id }) else { return }
        if states[id] != state { states[id] = state }
        save()
    }

    /// The folder's items by the name they'd have here, hidden ones left out.
    private func topLevel(_ source: BrowseLocation) async throws -> [String: BrowseLocation] {
        switch source {
        case .remote(let id, let path):
            guard let server = servers.server(id) else { throw CocoaError(.fileNoSuchFile) }
            let client = try await connections.browseClient(for: server)
            let folder = RemotePath(bytes: path)
            var items: [String: BrowseLocation] = [:]
            for entry in try await client.list(folder)
                where entry.filename.bytes.first != UInt8(ascii: ".") && (entry.attributes.isDirectory || entry.attributes.isRegularFile) {
                items[TransferPlan.localName(entry.filename)] = .remote(server: id, path: folder.appending(entry.filename).bytes)
            }
            return items
        case .local(let url):
            #if DEBUG
            guard TransferManager.isIsolated else { throw CocoaError(.featureUnsupported) }
            let names = try await Task.detached {
                try FileManager.default.contentsOfDirectory(atPath: url.path).filter { !$0.hasPrefix(".") }
            }.value
            return Dictionary(uniqueKeysWithValues: names.map { ($0, BrowseLocation.local(url.appendingPathComponent($0))) })
            #else
            _ = url
            throw CocoaError(.featureUnsupported)   // server folders only
            #endif
        }
    }

    /// An item's total size, newest change, and whether any part of it is still downloading.
    private func look(at name: String, _ location: BrowseLocation) async throws -> WatchEntry {
        switch location {
        case .remote(let id, let path):
            guard let server = servers.server(id) else { throw CocoaError(.fileNoSuchFile) }
            let client = try await connections.browseClient(for: server)
            let tree = try await remoteTree(at: RemotePath(bytes: path), using: client, includeHidden: true)
            let newest = tree.files.compactMap(\.modificationTime).max().map { Date(timeIntervalSince1970: TimeInterval($0)) }
            return WatchEntry(name: name, location: location, size: Int64(clamping: tree.files.saturatingSum(\.size)), newest: newest,
                              incomplete: tree.files.contains { Self.isPartial($0.relativePath) })
        case .local(let url):
            return try await Task.detached { () -> WatchEntry in
                let fm = FileManager.default
                var size: Int64 = 0, newest: Date?, partial = false
                func add(_ path: String) {
                    guard let attributes = try? fm.attributesOfItem(atPath: path), attributes[.type] as? FileAttributeType == .typeRegular else { return }
                    size += (attributes[.size] as? NSNumber)?.int64Value ?? 0
                    if let date = attributes[.modificationDate] as? Date, date > (newest ?? .distantPast) { newest = date }
                    if SeedboxWatch.isPartial(path) { partial = true }
                }
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { throw CocoaError(.fileNoSuchFile) }
                if isDirectory.boolValue {
                    for path in fm.enumerator(atPath: url.path)?.allObjects as? [String] ?? [] { add(url.appendingPathComponent(path).path) }
                } else {
                    add(url.path)
                }
                return WatchEntry(name: name, location: location, size: size, newest: newest, incomplete: partial)
            }.value
        }
    }

    // MARK: Keeping

    private struct Saved: Codable {
        var rules: [WatchRule]
        var states: [UUID: WatchState]
    }

    private func load() {
        guard !TransferManager.isIsolated, let data = try? Data(contentsOf: Self.file),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        rules = saved.rules
        states = saved.states
    }

    private func save() {
        guard !TransferManager.isIsolated, let data = try? JSONEncoder().encode(Saved(rules: rules, states: states)) else { return }
        try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.file, options: .atomic)
    }

    #if DEBUG
    /// What a look would decide for everything in `source` now, fetching
    /// nothing (the dry run against a real server): by qBittorrent's records,
    /// finished or still downloading; else left to the timing rules.
    func dryRun(_ source: BrowseLocation) async -> (items: Int, finished: Int, downloading: Int, unclaimed: Int, records: String?, excluded: Int)? {
        guard let items = try? await topLevel(source) else { return nil }
        let rule = WatchRule(source: source, destination: "/")
        var state = WatchState()
        let claims = await torrentClaims(for: Set(items.keys), rule: rule, state: &state)
        let finished = claims.values.filter { $0.allSatisfy(\.finished) }.count
        return (items.count, finished, claims.count - finished, items.count - claims.count, state.records, state.excluded.count)
    }

    /// Watching nothing (the tests).
    func reset() {
        rules = []
        states = [:]
    }
    #endif
}
