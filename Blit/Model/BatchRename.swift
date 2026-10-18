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
    /// For a step after the first: run only if the step above changed the name,
    /// so a preset for one kind of name leaves other names alone.
    var onlyIfPreviousChanged = true

    init() {}

    // Every field is optional when decoding, so rules saved before a field
    // existed still load.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RenameRule()
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? d.mode
        find = try c.decodeIfPresent(String.self, forKey: .find) ?? d.find
        replacement = try c.decodeIfPresent(String.self, forKey: .replacement) ?? d.replacement
        matchCase = try c.decodeIfPresent(Bool.self, forKey: .matchCase) ?? d.matchCase
        regularExpression = try c.decodeIfPresent(Bool.self, forKey: .regularExpression) ?? d.regularExpression
        addText = try c.decodeIfPresent(String.self, forKey: .addText) ?? d.addText
        addBefore = try c.decodeIfPresent(Bool.self, forKey: .addBefore) ?? d.addBefore
        format = try c.decodeIfPresent(Format.self, forKey: .format) ?? d.format
        customName = try c.decodeIfPresent(String.self, forKey: .customName) ?? d.customName
        numberBefore = try c.decodeIfPresent(Bool.self, forKey: .numberBefore) ?? d.numberBefore
        startAt = try c.decodeIfPresent(Int.self, forKey: .startAt) ?? d.startAt
        includeExtension = try c.decodeIfPresent(Bool.self, forKey: .includeExtension) ?? d.includeExtension
        onlyIfPreviousChanged = try c.decodeIfPresent(Bool.self, forKey: .onlyIfPreviousChanged) ?? d.onlyIfPreviousChanged
    }

    /// Runs `steps` in order. A later step marked onlyIfPreviousChanged is
    /// skipped (and so is everything after it) when the step before it left
    /// the name as it was.
    static func apply(_ steps: [RenameRule], to name: String, index: Int, date: Date) -> String {
        var current = name
        var changedByPrevious = true
        for (i, step) in steps.enumerated() {
            let next = step.apply(to: current, index: index, date: date)
            if i > 0, step.onlyIfPreviousChanged, !changedByPrevious { break }
            changedByPrevious = next != current
            current = next
        }
        return current
    }

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

    /// "starts with a space", "ends with 2 spaces", "is a space"… for text
    /// with spaces at either end, which a text field doesn't show (the sheet
    /// opens with the last rule, so a field that looks empty can hold one, and
    /// typing after it finds nothing); nil when there are none.
    static func edgeSpaces(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        func spaces(_ n: Int) -> String { n == 1 ? "a space" : "\(n) spaces" }
        let leading = text.prefix(while: \.isWhitespace).count
        if leading == text.count { return text.count == 1 ? "is a space" : "is \(text.count) spaces" }
        let trailing = text.reversed().prefix(while: \.isWhitespace).count
        switch (leading, trailing) {
        case (0, 0): return nil
        case (_, 0): return "starts with \(spaces(leading))"
        case (0, _): return "ends with \(spaces(trailing))"
        default: return "starts with \(spaces(leading)) and ends with \(spaces(trailing))"
        }
    }

    /// `text` with every space drawn as ␣, to show exactly what's typed.
    static func visibleSpaces(_ text: String) -> String {
        String(text.map { $0.isWhitespace ? "␣" : $0 })
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

/// Saved steps with a name ("Movies"), in user defaults.
struct RenamePreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var steps: [RenameRule]

    init(name: String, steps: [RenameRule]) {
        self.name = name
        self.steps = steps
    }

    enum CodingKeys: String, CodingKey { case id, name, steps, rule }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        // Presets saved with a single rule.
        steps = try c.decodeIfPresent([RenameRule].self, forKey: .steps)
            ?? [c.decode(RenameRule.self, forKey: .rule)]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(steps, forKey: .steps)
    }
}

@MainActor
enum RenamePresets {
    private static let key = "renamePresets"
    private static let versionKey = "renamePresetsVersion"
    /// 2: words separated by spaces, underscores or hyphens too, not only dots.
    private static let version = 2

    /// The user's defaults; a test copy's own scratch suite, so tests never
    /// write the user's presets.
    private static var store: UserDefaults {
        TransferManager.isIsolated ? UserDefaults(suiteName: "com.banastas.blit.test-presets") ?? .standard : .standard
    }

    static func all() -> [RenamePreset] {
        seedIfNeeded()
        upgradeIfNeeded()
        guard let data = store.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([RenamePreset].self, from: data)) ?? []
    }

    /// The user's naming conventions, added once (they can be edited or deleted):
    /// Movies "The.Gentlemen.2019.UHD…mkv" → "The Gentlemen 2019.mkv";
    /// TV "South.Park.S29E01.1080p…mkv" → "South-Park_S29E01.mkv". Words may be
    /// separated by dots, spaces, underscores or hyphens ("Some Show S01E02
    /// Title 1080p…mkv" → "Some-Show_S01E02.mkv"), and the episode is written
    /// in capitals ("s01e03" → "S01E03").
    static var conventions: [RenamePreset] {
        var movieTitle = RenameRule()
        movieTitle.find = #"^(.+)[. _-]((?:19|20)\d{2})(?:[. _-].*)?$"#   // the last year in the name
        movieTitle.replacement = "$1 $2"
        movieTitle.regularExpression = true
        var movieSpaces = RenameRule()
        movieSpaces.find = "[._]+"
        movieSpaces.replacement = " "
        movieSpaces.regularExpression = true
        var episode = RenameRule()
        episode.find = #"^(.+?)[. _-]+(S\d{2,}E\d{2,}(?:-?E\d{2,})*)(?:[. _-].*)?$"#
        episode.replacement = "$1_$2"
        episode.regularExpression = true
        var showHyphens = RenameRule()
        showHyphens.find = #"[. _]+(?=.*_S\d{2,}E\d{2,})"#   // in the show's name, not the _ before the episode
        showHyphens.replacement = "-"
        showHyphens.regularExpression = true
        var episodeCapitals = RenameRule()
        episodeCapitals.find = #"_S(\d{2,})E(\d{2,})"#
        episodeCapitals.replacement = "_S$1E$2"
        episodeCapitals.regularExpression = true
        episodeCapitals.onlyIfPreviousChanged = false   // also for a one-word name (Show_s01e01)
        return [RenamePreset(name: "Movies (Title Year)", steps: [movieTitle, movieSpaces]),
                RenamePreset(name: "TV Shows (Show-Name_S01E01)", steps: [episode, showHyphens, episodeCapitals])]
    }

    /// The conventions as shipped until 1.0.4: dots between words only.
    static var conventionsV1: [RenamePreset] {
        var movieTitle = RenameRule()
        movieTitle.find = #"^(.+)\.((?:19|20)\d{2})(?:\..*)?$"#
        movieTitle.replacement = "$1 $2"
        movieTitle.regularExpression = true
        var movieSpaces = RenameRule()
        movieSpaces.find = "."
        movieSpaces.replacement = " "
        var episode = RenameRule()
        episode.find = #"^(.+?)\.(S\d{2,}E\d{2,}(?:-?E\d{2,})*)(?:\..*)?$"#
        episode.replacement = "$1_$2"
        episode.regularExpression = true
        var showHyphens = RenameRule()
        showHyphens.find = "."
        showHyphens.replacement = "-"
        return [RenamePreset(name: "Movies (Title Year)", steps: [movieTitle, movieSpaces]),
                RenamePreset(name: "TV Shows (Show-Name_S01E01)", steps: [episode, showHyphens])]
    }

    private static func seedIfNeeded() {
        let store = store
        guard !store.bool(forKey: "renamePresetsSeeded") else { return }
        store.set(true, forKey: "renamePresetsSeeded")
        store.set(version, forKey: versionKey)
        var existing: [RenamePreset] = []
        if let data = store.data(forKey: key) {
            existing = (try? JSONDecoder().decode([RenamePreset].self, from: data)) ?? []
        }
        save(existing + conventions.filter { preset in !existing.contains { $0.name == preset.name } })
    }

    /// A saved preset still exactly as an earlier Blit shipped it takes the
    /// current steps, once; one the user changed is left as it is.
    private static func upgradeIfNeeded() {
        let store = store
        guard store.integer(forKey: versionKey) < version else { return }
        store.set(version, forKey: versionKey)
        guard let data = store.data(forKey: key),
              var saved = try? JSONDecoder().decode([RenamePreset].self, from: data) else { return }
        var changed = false
        for i in saved.indices {
            guard let shipped = conventionsV1.first(where: { $0.name == saved[i].name }), shipped.steps == saved[i].steps,
                  let current = conventions.first(where: { $0.name == saved[i].name }) else { continue }
            saved[i].steps = current.steps
            changed = true
        }
        if changed { save(saved) }
    }

    static func save(_ presets: [RenamePreset]) {
        if let data = try? JSONEncoder().encode(presets) { store.set(data, forKey: key) }
    }

    #if DEBUG
    /// Test copies: forget the scratch suite's presets.
    static func resetTestStore() {
        guard TransferManager.isIsolated else { return }
        store.removePersistentDomain(forName: "com.banastas.blit.test-presets")
    }
    #endif
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
    static func rows(_ items: [FileItem], steps: [RenameRule], siblings: (BrowseLocation) -> [String]) -> [RenamePlanRow] {
        var rows = items.enumerated().map { index, item in
            RenamePlanRow(item: item, newName: RenameRule.apply(steps, to: item.name, index: index, date: item.modified)
                .trimmingCharacters(in: .whitespaces))
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
