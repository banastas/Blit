// Rename several items at once (File › Rename N Items…), as in Finder: replace
// text, add text, or a format with a number or date. Rules can be saved as
// presets for naming conventions. The extension is kept unless the rule is
// told to include it.

import Foundation
import UniformTypeIdentifiers

struct RenameRule: Codable, Equatable, Hashable {
    enum Mode: String, Codable, CaseIterable { case replace, add, format }
    enum Format: String, Codable, CaseIterable { case index, counter, date }

    var mode: Mode = .replace
    // Replace Text
    var find = ""
    var replacement = ""
    var matchCase = false
    var regularExpression = false
    // Add Text
    var addText = ""
    var addBefore = false
    // Format
    var format: Format = .index
    var customName = ""
    var numberBefore = false
    var startAt = 1
    /// Apply to the whole name, extension included (off: the extension is kept as is).
    var includeExtension = false

    /// The new name for `name`, the `index`-th item (0-based) of the batch.
    /// `date` is the item's modification date (Name and Date).
    func apply(to name: String, index: Int, date: Date) -> String {
        let (base, ext) = includeExtension ? (name, "") : Self.split(name)
        let renamed: String
        switch mode {
        case .replace:
            guard !find.isEmpty else { return name }
            if regularExpression {
                guard let regex = try? NSRegularExpression(pattern: find, options: matchCase ? [] : [.caseInsensitive]) else { return name }
                renamed = regex.stringByReplacingMatches(in: base, range: NSRange(base.startIndex..., in: base), withTemplate: replacement)
            } else {
                renamed = base.replacingOccurrences(of: find, with: replacement, options: matchCase ? [] : [.caseInsensitive])
            }
        case .add:
            renamed = addBefore ? addText + base : base + addText
        case .format:
            let number: String
            switch format {
            case .index: number = String(startAt + index)
            case .counter: number = String(format: "%05d", startAt + index)
            case .date: number = date.formatted(.iso8601.year().month().day()) + " at " + Self.time.string(from: date)
            }
            let custom = customName.isEmpty ? "File" : customName
            renamed = numberBefore ? "\(number) \(custom)" : (format == .date ? "\(custom) \(number)" : "\(custom)\(number)")
        }
        return ext.isEmpty ? renamed : renamed + "." + ext
    }

    /// Whether the rule changes anything yet (a Replace with nothing to find doesn't).
    var isActive: Bool {
        switch mode {
        case .replace: !find.isEmpty
        case .add: !addText.isEmpty
        case .format: true
        }
    }

    /// "name.tar.gz" keeps only the last extension, and only a plausible one
    /// (as Finder does): a dot in "Some.Show.S01E02" isn't an extension unless
    /// it's a known type.
    static func split(_ name: String) -> (base: String, ext: String) {
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        guard !ext.isEmpty, ext.count <= 8, !ext.contains(" "), name.count > ext.count + 1,
              UTType(filenameExtension: ext).map({ !$0.isDynamic }) ?? false else { return (name, "") }
        return (String(name.dropLast(ext.count + 1)), ext)
    }

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH.mm.ss"
        return f
    }()
}

/// A saved rule with a name ("Scene → Plex"), in user defaults.
struct RenamePreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var rule: RenameRule
}

@MainActor
enum RenamePresets {
    private static let key = "renamePresets"

    static func all() -> [RenamePreset] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RenamePreset].self, from: data)) ?? []
    }

    static func save(_ presets: [RenamePreset]) {
        if let data = try? JSONEncoder().encode(presets) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// One row of the preview: the item, its new name, and what's wrong (if anything).
struct RenamePlanRow: Identifiable {
    var item: FileItem
    var newName: String
    var problem: String?
    var id: BrowseLocation { item.location }
    var changes: Bool { Array(newName.utf8) != Array(item.name.utf8) }
}

enum RenamePlan {
    /// New names for `items` under `rule`, with problems: an invalid name, two
    /// items given the same name, or a name another item in the folder has.
    /// `siblings` gives the other names in each item's folder.
    static func rows(_ items: [FileItem], rule: RenameRule, siblings: (BrowseLocation) -> [String]) -> [RenamePlanRow] {
        var rows = items.enumerated().map { index, item in
            RenamePlanRow(item: item, newName: rule.apply(to: item.name, index: index, date: item.modified).trimmingCharacters(in: .whitespaces))
        }
        let batch = Set(items.map(\.location))
        for i in rows.indices where rows[i].changes {
            let name = rows[i].newName
            if name.isEmpty || name.contains("/") || name == "." || name == ".." {
                rows[i].problem = "isn't a valid name"
                continue
            }
            let parent = rows[i].item.location.parent
            let clash = rows.indices.contains { j in
                j != i && rows[j].item.location.parent == parent && rows[j].newName.lowercased() == name.lowercased()
            }
            if clash { rows[i].problem = "two items would get this name"; continue }
            // A name another item in the folder already has (unless that item is being renamed too).
            let others = parent.map(siblings) ?? []
            let renamedAway = Set(items.filter { batch.contains($0.location) && $0.location.parent == parent }.map { $0.name.lowercased() })
            if others.contains(where: { $0.lowercased() == name.lowercased() && !renamedAway.contains($0.lowercased()) }),
               name.lowercased() != rows[i].item.name.lowercased() {
                rows[i].problem = "already exists"
            }
        }
        return rows
    }
}
