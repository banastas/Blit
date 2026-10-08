// qBittorrent's own records of its torrents (PRD R5.10), for watch mode: the
// BT_backup folder beside its settings holds, for each torrent, its .torrent
// file (the name it downloads as, and its files) and its .fastresume
// (libtorrent's resume data: where it saves, which pieces it has, and when
// it completed — 0 until it does). Read over SFTP like any file, so no login
// to qBittorrent is needed; a torrent that has stalled shows as unfinished
// however long its files have been quiet.

import Foundation

/// A bencoded value (BEP 3): integers, byte strings, lists, dictionaries.
indirect enum Bencode: Equatable {
    case integer(Int)
    case bytes(Data)
    case list([Bencode])
    case dictionary([String: Bencode])

    subscript(key: String) -> Bencode? {
        if case .dictionary(let entries) = self { return entries[key] }
        return nil
    }

    var int: Int? { if case .integer(let value) = self { value } else { nil } }
    var data: Data? { if case .bytes(let value) = self { value } else { nil } }
    var string: String? { data.map { String(decoding: $0, as: UTF8.self) } }
    var array: [Bencode]? { if case .list(let values) = self { values } else { nil } }

    static func decode(_ data: Data) -> Bencode? {
        let bytes = [UInt8](data)
        var index = 0
        func value(_ depth: Int) -> Bencode? {
            guard index < bytes.count, depth < 64 else { return nil }
            switch bytes[index] {
            case UInt8(ascii: "i"):
                index += 1
                guard let end = bytes[index...].firstIndex(of: UInt8(ascii: "e")),
                      let number = Int(String(decoding: bytes[index..<end], as: UTF8.self)) else { return nil }
                index = end + 1
                return .integer(number)
            case UInt8(ascii: "l"):
                index += 1
                var values: [Bencode] = []
                while index < bytes.count, bytes[index] != UInt8(ascii: "e") {
                    guard let item = value(depth + 1) else { return nil }
                    values.append(item)
                }
                index += 1
                return .list(values)
            case UInt8(ascii: "d"):
                index += 1
                var entries: [String: Bencode] = [:]
                while index < bytes.count, bytes[index] != UInt8(ascii: "e") {
                    guard case .bytes(let key)? = value(depth + 1), let item = value(depth + 1) else { return nil }
                    entries[String(decoding: key, as: UTF8.self)] = item
                }
                index += 1
                return .dictionary(entries)
            default:
                guard let colon = bytes[index...].firstIndex(of: UInt8(ascii: ":")),
                      let length = Int(String(decoding: bytes[index..<colon], as: UTF8.self)), length >= 0,
                      colon + 1 + length <= bytes.count else { return nil }
                index = colon + 1 + length
                return .bytes(Data(bytes[(colon + 1)..<(colon + 1 + length)]))
            }
        }
        return value(0)
    }
}

/// What a torrent's .fastresume says, for its status in a server pane (and
/// whether it's finished, for watch mode).
struct TorrentResume: Equatable, Sendable {
    var savePath: String
    var finished: Bool
    /// Pieces it has, of all of them, when the record was last written
    /// (qBittorrent rewrites them about hourly).
    var fraction: Double
    /// Seconds spent seeding, uploaded and downloaded bytes, all-time.
    var seedingTime: TimeInterval
    var uploaded: Int64
    var downloaded: Int64
    /// Its own share limits: nil follows qBittorrent's global ones, negative is none.
    var ratioLimit: Double?
    var seedingMinutesLimit: Int?
    /// Stopped (paused, not managed by the queue) or waiting in the queue.
    var stopped: Bool
    var queued: Bool
    /// When it last received data, and when it finished.
    var lastDownload: Date?
    var completed: Date?
    /// qBittorrent's content layout ("Original", "Subfolder", "NoSubfolder"),
    /// and the first names of any files renamed in qBittorrent.
    var layout: String? = nil
    var renamedRoots: Set<String> = []
}

/// qBittorrent's settings that bear on a torrent's status.
struct TorrentSettings: Equatable, Sendable {
    /// Global share limits (negative: none).
    var ratioLimit: Double = -1
    var seedingMinutesLimit: Int = -1
    /// Files are allocated in full when added, so the space they take on disk
    /// says nothing about how far they've come.
    var preallocates = false
}

/// What a .torrent file says: the names it may put in its save folder, and its size.
struct TorrentMetadata: Equatable, Sendable {
    var names: Set<String>
    var size: Int64
    /// Its own name, and for several files, each one's first folder or name.
    var name: String = ""
    var fileRoots: Set<String> = []
}

/// One torrent, as qBittorrent's records describe it.
struct TorrentRecord: Equatable {
    /// The names it puts directly in its save folder: its own name, and for a
    /// torrent of several files, each file's first folder (as a torrent added
    /// without a subfolder lays them out).
    var names: Set<String>
    var savePath: String
    var finished: Bool
    /// Pieces it has, of all of them.
    var fraction: Double
}

enum TorrentRecords {
    /// Where qBittorrent keeps them, relative to the login's home: its usual
    /// Linux places, and a seedbox's app folder (~/.apps/qbittorrent).
    static let candidates = [".apps/qbittorrent/qBittorrent/BT_backup", ".local/share/qBittorrent/BT_backup",
                             ".local/share/data/qBittorrent/BT_backup", ".config/qBittorrent/BT_backup"]

    /// What a .torrent file says: its name and its files' first folders.
    static func names(torrent data: Data) -> Set<String>? {
        guard let info = Bencode.decode(data)?["info"], let name = (info["name.utf-8"] ?? info["name"])?.string else { return nil }
        var names: Set<String> = [name]
        for file in info["files"]?.array ?? [] {
            if let first = (file["path.utf-8"] ?? file["path"])?.array?.first?.string { names.insert(first) }
        }
        return names
    }

    /// Its names and total size.
    static func metadata(torrent data: Data) -> TorrentMetadata? {
        guard let names = names(torrent: data), let info = Bencode.decode(data)?["info"] else { return nil }
        let size = info["length"]?.int ?? (info["files"]?.array ?? []).reduce(0) { $0 + ($1["length"]?.int ?? 0) }
        let name = (info["name.utf-8"] ?? info["name"])?.string ?? ""
        let roots = Set((info["files"]?.array ?? []).compactMap { ($0["path.utf-8"] ?? $0["path"])?.array?.first?.string })
        return TorrentMetadata(names: names, size: Int64(size), name: name, fileRoots: roots)
    }

    /// Everything a .fastresume says that a status needs.
    static func resume(_ data: Data) -> TorrentResume? {
        guard let resume = Bencode.decode(data), let basic = state(resume: data) else { return nil }
        func date(_ key: String) -> Date? { resume[key]?.int.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil } }
        // qBittorrent keeps a ratio limit × 1000, and -2 (× 1000 for the ratio)
        // for "as the global setting", -1 for none.
        let ratio = resume["qBt-ratioLimit"]?.int.flatMap { $0 == -2000 ? nil : Double($0) / 1000 }
        let minutes = resume["qBt-seedingTimeLimit"]?.int.flatMap { $0 == -2 ? nil : $0 }
        let paused = (resume["paused"]?.int ?? 0) != 0, managed = (resume["auto_managed"]?.int ?? 0) != 0
        return TorrentResume(savePath: basic.savePath, finished: basic.finished, fraction: basic.fraction,
                             seedingTime: TimeInterval(resume["seeding_time"]?.int ?? 0),
                             uploaded: Int64(resume["total_uploaded"]?.int ?? 0), downloaded: Int64(resume["total_downloaded"]?.int ?? 0),
                             ratioLimit: ratio, seedingMinutesLimit: minutes, stopped: paused && !managed, queued: paused && managed,
                             lastDownload: date("last_download"), completed: date("completed_time"),
                             layout: resume["qBt-contentLayout"]?.string,
                             renamedRoots: Set((resume["mapped_files"]?.array ?? []).compactMap { entry -> String? in
                                 guard let path = entry.string, !path.isEmpty else { return nil }
                                 return path.split(separator: "/").first.map(String.init)
                             }))
    }

    /// The share limits and allocation in qBittorrent.conf.
    static func settings(_ text: String) -> TorrentSettings {
        var settings = TorrentSettings()
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Session\\GlobalMaxRatio": settings.ratioLimit = Double(parts[1]) ?? -1
            case "Session\\GlobalMaxSeedingMinutes": settings.seedingMinutesLimit = Int(parts[1]) ?? -1
            case "Session\\Preallocation": settings.preallocates = parts[1].lowercased() == "true"
            default: break
            }
        }
        return settings
    }

    /// What a .fastresume says: where it saves, whether it completed, how much it has.
    static func state(resume data: Data) -> (savePath: String, finished: Bool, fraction: Double)? {
        guard let resume = Bencode.decode(data) else { return nil }
        let save = [resume["qBt-savePath"]?.string, resume["save_path"]?.string].compactMap { $0 }.first { !$0.isEmpty } ?? ""
        let pieces = resume["pieces"]?.data ?? Data()
        let have = pieces.reduce(0) { $0 + Int($1 & 1) }
        let complete = !pieces.isEmpty && have == pieces.count
        let finished = (resume["completed_time"]?.int ?? 0) > 0 || complete
        return (save.hasSuffix("/") ? String(save.dropLast()) : save, finished, pieces.isEmpty ? (finished ? 1 : 0) : Double(have) / Double(pieces.count))
    }
}
