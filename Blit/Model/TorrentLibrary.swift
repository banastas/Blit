// qBittorrent's records on a server, read once and shared: watch mode asks
// which items are finished (PRD R5.10), server panes show each torrent's
// status (R2.25). Read over SFTP like any file (BT_backup beside its
// settings), each file again only when it changes. qBittorrent rewrites its
// records about hourly, so how far a download has come is read live from its
// files instead: they're sparse, and fill in on disk as pieces arrive.

import BlitRemote
import BlitSFTP
import Foundation

/// One torrent in qBittorrent's records.
struct TorrentEntry: Equatable, Sendable {
    /// Its records' file name, without the extension (the info hash).
    var id: String
    /// Every name it may put in its save folder (watch mode holds back any of them).
    var names: Set<String>
    /// The names it does put there, by its layout: its own name (a file, or
    /// its files' folder), its files' first names without a subfolder, or
    /// what they were renamed to in qBittorrent.
    var placed: Set<String> = []
    var size: Int64
    var resume: TorrentResume
    /// When its .fastresume was last written.
    var recorded: Date?
}

/// How much of a torrent's data is on disk now, and when it last grew.
struct TorrentLiveBytes: Equatable, Sendable {
    var bytes: Int64
    var newestWrite: Date?
}

@MainActor
final class TorrentLibrary {
    /// The app's (watch mode and the status board reach it here).
    static var shared: TorrentLibrary?

    private let servers: ServerStore
    private let connections: ConnectionManager
    /// Where each server keeps its records (nil: none found), looked for again daily.
    private var found: [String: (folder: String?, checked: Date)] = [:]
    private var settingsRead: [String: (settings: TorrentSettings?, text: String?, read: Date)] = [:]
    private var metadata: [String: (modified: Date?, metadata: TorrentMetadata)] = [:]
    private var resumes: [String: (modified: Date?, resume: TorrentResume)] = [:]
    private var absolutes: [BrowseLocation: String] = [:]
    /// Whether a server's shell has GNU find (for the live check).
    private var canFind: [String: Bool] = [:]

    init(servers: ServerStore, connections: ConnectionManager) {
        self.servers = servers
        self.connections = connections
    }

    /// The records folder for the server `location` is on (relative to the
    /// login's home), if qBittorrent keeps one there.
    func recordsFolder(for location: BrowseLocation, recheck: Bool = false) async -> String? {
        let key = Self.serverKey(location)
        if !recheck, let known = found[key], Date().timeIntervalSince(known.checked) < 86_400 { return known.folder }
        guard let access = try? await access(location) else { return nil }
        let folder = await access.find()
        found[key] = (folder, Date())
        return folder
    }

    /// qBittorrent.conf's text and what it says, read again every ten minutes.
    func settings(for location: BrowseLocation, records: String) async -> (text: String, settings: TorrentSettings)? {
        let key = Self.serverKey(location)
        if let read = settingsRead[key], Date().timeIntervalSince(read.read) < 600 {
            return read.text.map { ($0, read.settings ?? TorrentSettings()) }
        }
        guard let access = try? await access(location) else { return nil }
        let text = await access.settings(records)
        settingsRead[key] = (text.map(TorrentRecords.settings), text, Date())
        return text.map { ($0, TorrentRecords.settings($0)) }
    }

    /// `folder` as the server spells it in full (as qBittorrent's save paths are).
    func absolutePath(_ folder: BrowseLocation) async -> String? {
        if let known = absolutes[folder] { return known }
        guard let access = try? await access(folder), let path = try? await access.absolute() else { return nil }
        absolutes[folder] = path
        return path
    }

    /// Every torrent in `records` (a records folder on `location`'s server).
    func torrents(in records: String, on location: BrowseLocation) async -> [TorrentEntry]? {
        guard let access = try? await access(location), let files = try? await access.list(records) else { return nil }
        let server = Self.serverKey(location)
        let byName = Dictionary(files.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var entries: [TorrentEntry] = []
        for torrent in files where torrent.name.hasSuffix(".torrent") {
            let id = String(torrent.name.dropLast(".torrent".count))
            guard let resumeFile = byName[id + ".fastresume"] else { continue }
            let torrentKey = server + "|" + records + "/" + torrent.name
            if metadata[torrentKey]?.modified != torrent.modified || metadata[torrentKey] == nil {
                guard let data = try? await access.read(records + "/" + torrent.name, torrent.size),
                      let read = TorrentRecords.metadata(torrent: data) else { continue }
                metadata[torrentKey] = (torrent.modified, read)
            }
            let resumeKey = server + "|" + records + "/" + resumeFile.name
            if resumes[resumeKey]?.modified != resumeFile.modified || resumes[resumeKey] == nil {
                guard let data = try? await access.read(records + "/" + resumeFile.name, resumeFile.size),
                      let read = TorrentRecords.resume(data) else { continue }
                resumes[resumeKey] = (resumeFile.modified, read)
            }
            guard let meta = metadata[torrentKey]?.metadata, let resume = resumes[resumeKey]?.resume else { continue }
            let placed: Set<String> = !resume.renamedRoots.isEmpty ? resume.renamedRoots
                : !meta.fileRoots.isEmpty && resume.layout == "NoSubfolder" ? meta.fileRoots
                : [meta.name]
            entries.append(TorrentEntry(id: id, names: meta.names, placed: placed, size: meta.size, resume: resume, recorded: resumeFile.modified))
        }
        return entries
    }

    /// For each of `paths` (absolute, on `location`'s server): the bytes its
    /// files take on disk and when one was last written. nil when the server
    /// can't say (no shell, or no GNU find).
    func liveBytes(_ paths: [String], on location: BrowseLocation) async -> [TorrentLiveBytes]? {
        guard !paths.isEmpty else { return [] }
        switch location {
        case .remote(let id, _):
            guard let server = servers.server(id), let client = try? await connections.browseClient(for: server) else { return nil }
            let key = Self.serverKey(location)
            if canFind[key] == nil {
                let probe = try? await client.connection.run("find . -maxdepth 0 -printf '%b %T@\\n'")
                canFind[key] = probe.map { $0.exitStatus == 0 && Self.parseFind(String(decoding: $0.stdout, as: UTF8.self)).first != nil } ?? false
            }
            guard canFind[key] == true else { return nil }
            // One line per file (512-byte blocks allocated, modification time),
            // each path's after a "==" line; NUL-separated paths need no quoting.
            let script = #"for p; do echo ==; find "$p" -type f -printf "%b %T@\n" 2>/dev/null; done"#
            let input: [UInt8] = paths.flatMap { Array($0.utf8) + [UInt8(0)] }
            guard let result = try? await client.connection.run("xargs -0 sh -c '\(script)' sh", stdin: input) else { return nil }
            let groups = Self.splitFind(String(decoding: result.stdout, as: UTF8.self))
            guard groups.count == paths.count else { return nil }
            return groups
        case .local:
            #if DEBUG
            guard TransferManager.isIsolated, UserDefaults.standard.string(forKey: "BlitWatchRecordsHome") != nil else { return nil }
            return await Task.detached { paths.map(Self.localBytes) }.value
            #else
            return nil
            #endif
        }
    }

    /// "blocks mtime" lines, per "==" group.
    nonisolated static func splitFind(_ output: String) -> [TorrentLiveBytes] {
        var groups: [TorrentLiveBytes] = []
        var lines: [Substring] = []
        func close() { groups.append(Self.total(parseFind(lines.joined(separator: "\n")))) }
        var started = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "==" {
                if started { close() }
                started = true
                lines = []
            } else if started, !line.isEmpty {
                lines.append(line)
            }
        }
        if started { close() }
        return groups
    }

    nonisolated static func parseFind(_ text: String) -> [(blocks: Int64, modified: Double)] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ")
            guard parts.count == 2, let blocks = Int64(parts[0]), let modified = Double(parts[1]) else { return nil }
            return (blocks, modified)
        }
    }

    nonisolated private static func total(_ files: [(blocks: Int64, modified: Double)]) -> TorrentLiveBytes {
        TorrentLiveBytes(bytes: files.reduce(0) { $0 + $1.blocks * 512 },
                         newestWrite: files.map(\.modified).max().map { Date(timeIntervalSince1970: $0) })
    }

    /// The same, for a test copy's stand-in files on this Mac.
    nonisolated private static func localBytes(_ path: String) -> TorrentLiveBytes {
        var files: [(blocks: Int64, modified: Double)] = []
        func add(_ file: String) {
            var info = Darwin.stat()
            guard lstat(file, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return }
            files.append((Int64(info.st_blocks), Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9))
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) else { return TorrentLiveBytes(bytes: 0, newestWrite: nil) }
        if isFolder.boolValue {
            for case let name as String in FileManager.default.enumerator(atPath: path) ?? NSEnumerator() { add(path + "/" + name) }
        } else {
            add(path)
        }
        return total(files)
    }

    nonisolated static func serverKey(_ location: BrowseLocation) -> String {
        if case .remote(let id, _) = location { return id.uuidString }
        return "this Mac"
    }

    // MARK: Reaching the records

    struct RecordFile {
        var name: String
        var size: UInt64
        var modified: Date?
    }

    /// Reading qBittorrent's records: over SFTP, or (a test copy's stand-in)
    /// on this Mac, with -BlitWatchRecordsHome.
    struct RecordAccess {
        var find: () async -> String?
        var absolute: () async throws -> String
        var list: (String) async throws -> [RecordFile]
        var read: (String, UInt64) async throws -> Data
        /// qBittorrent's settings file, beside its records or in ~/.config.
        var settings: (String) async -> String?
    }

    /// qBittorrent.conf beside BT_backup (a seedbox's app folder), or where Linux keeps it.
    nonisolated static func settingsCandidates(_ records: String) -> [String] {
        [(records as NSString).deletingLastPathComponent + "/qBittorrent.conf", ".config/qBittorrent/qBittorrent.conf"]
    }

    private static func readRemote(_ file: String, size: UInt64, client: SFTPClient) async throws -> Data {
        guard size <= 32 << 20 else { throw CocoaError(.fileReadTooLarge) }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("blit-records-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let part = try PartFile.create(at: scratch.path, size: size)
        defer { part.close() }
        if size > 0 { _ = try await client.download(RemotePath(file), range: 0..<size, into: part) { _ in } }
        return try Data(contentsOf: scratch)
    }

    func access(_ location: BrowseLocation) async throws -> RecordAccess {
        switch location {
        case .remote(let id, let path):
            guard let server = servers.server(id) else { throw CocoaError(.fileNoSuchFile) }
            let client = try await connections.browseClient(for: server)
            return RecordAccess(
                find: {
                    for candidate in TorrentRecords.candidates {
                        if let attributes = try? await client.stat(RemotePath(candidate)), attributes.isDirectory { return candidate }
                    }
                    return nil
                },
                absolute: { try await client.realpath(RemotePath(bytes: path.isEmpty ? Array(".".utf8) : path)).description },
                list: { folder in
                    try await client.list(RemotePath(folder)).map { entry in
                        RecordFile(name: entry.filename.description, size: entry.attributes.size ?? 0,
                                   modified: entry.attributes.modificationTime.map { Date(timeIntervalSince1970: TimeInterval($0)) })
                    }
                },
                read: { file, size in try await Self.readRemote(file, size: size, client: client) },
                settings: { records in
                    for candidate in Self.settingsCandidates(records) {
                        guard let size = try? await client.stat(RemotePath(candidate)).size,
                              let data = try? await Self.readRemote(candidate, size: size, client: client) else { continue }
                        return String(decoding: data, as: UTF8.self)
                    }
                    return nil
                })
        case .local(let url):
            #if DEBUG
            guard TransferManager.isIsolated, let home = UserDefaults.standard.string(forKey: "BlitWatchRecordsHome") else {
                throw CocoaError(.featureUnsupported)
            }
            let base = URL(fileURLWithPath: home)
            return RecordAccess(
                find: { TorrentRecords.candidates.first { FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path) } },
                absolute: { url.path },
                list: { folder in
                    let directory = base.appendingPathComponent(folder)
                    return try FileManager.default.contentsOfDirectory(atPath: directory.path).map { name in
                        let attributes = try? FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(name).path)
                        return RecordFile(name: name, size: (attributes?[.size] as? NSNumber)?.uint64Value ?? 0,
                                          modified: attributes?[.modificationDate] as? Date)
                    }
                },
                read: { file, _ in try Data(contentsOf: base.appendingPathComponent(file)) },
                settings: { records in
                    Self.settingsCandidates(records).lazy.compactMap { try? String(contentsOf: base.appendingPathComponent($0), encoding: .utf8) }.first
                })
            #else
            _ = url
            throw CocoaError(.featureUnsupported)
            #endif
        }
    }

    #if DEBUG
    /// Forgets everything read (a test's stand-in records change under it).
    func forget() {
        found = [:]
        settingsRead = [:]
        metadata = [:]
        resumes = [:]
        absolutes = [:]
        canFind = [:]
    }
    #endif
}
