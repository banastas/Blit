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
