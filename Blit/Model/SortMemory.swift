// Sort order remembered per folder, as Finder does: a folder sorted by name
// stays sorted by name; everything else opens newest first (PRD R2.4).

import Foundation

enum SortColumn: String, CaseIterable {
    case name, modified, size, kind

    var title: String {
        switch self {
        case .name: "Name"
        case .modified: "Date Modified"
        case .size: "Size"
        case .kind: "Kind"
        }
    }

    /// The direction a column starts in, as in Finder: names and kinds A–Z,
    /// dates newest first, sizes largest first.
    var defaultOrder: SortOrder {
        switch self {
        case .name, .kind: .forward
        case .modified, .size: .reverse
        }
    }

    func comparator(_ order: SortOrder? = nil) -> KeyPathComparator<FileItem> {
        let order = order ?? defaultOrder
        switch self {
        case .name: return KeyPathComparator(\FileItem.name, order: order)
        case .modified: return KeyPathComparator(\FileItem.modified, order: order)
        case .size: return KeyPathComparator(\FileItem.size, order: order)
        case .kind: return KeyPathComparator(\FileItem.kind, order: order)
        }
    }

    init?(_ comparator: KeyPathComparator<FileItem>?) {
        guard let comparator else { return nil }
        guard let column = Self.allCases.first(where: { $0.comparator().keyPath == comparator.keyPath }) else { return nil }
        self = column
    }
}

@MainActor
enum SortMemory {
    static let standard = [SortColumn.modified.comparator()]
    private static let key = "sortOrders"
    /// Folders remembered at most; the oldest are forgotten first.
    private static let limit = 1000

    static func order(for location: BrowseLocation) -> [KeyPathComparator<FileItem>] {
        // Saved as [column, "asc"/"desc", time saved].
        guard let saved = entries()[id(location)], saved.count >= 2,
              let column = SortColumn(rawValue: saved[0]) else { return standard }
        return [column.comparator(saved[1] == "asc" ? .forward : .reverse)]
    }

    /// Remembers `order` for `location`; the standard order is simply forgotten.
    static func set(_ order: [KeyPathComparator<FileItem>], for location: BrowseLocation) {
        var all = entries()
        let key = id(location)
        all[key] = nil
        if let first = order.first, let column = SortColumn(first),
           !(column == .modified && first.order == .reverse) {
            all[key] = [column.rawValue, first.order == .forward ? "asc" : "desc", String(Date().timeIntervalSince1970)]
        }
        if all.count > limit {
            let oldest = all.sorted { (Double($0.value.dropFirst(2).first ?? "") ?? 0) < (Double($1.value.dropFirst(2).first ?? "") ?? 0) }
            for (key, _) in oldest.prefix(all.count - limit) { all[key] = nil }
        }
        UserDefaults.standard.set(all, forKey: Self.key)
    }

    private static func entries() -> [String: [String]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [String]] ?? [:]
    }

    private static func id(_ location: BrowseLocation) -> String {
        switch location {
        case .local(let url): "local:" + url.standardizedFileURL.path
        case .remote(let server, let path): "remote:\(server.uuidString):" + Data(path).base64EncodedString()
        }
    }
}
