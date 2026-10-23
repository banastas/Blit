// ⌘K: jump to any favorite, server, drive, NAS share or recent folder by
// typing (PRD R2.7).

import SwiftUI

struct PaletteEntry: Identifiable, Hashable {
    enum Group: String { case favorite = "Favorite", server = "Server", drive = "Drive", nas = "Network", recent = "Recent" }
    let location: BrowseLocation
    let name: String
    let detail: String
    let symbol: String
    let group: Group
    var id: String { "\(group.rawValue):\(name):\(detail)" }
}

struct CommandPalette: View {
    let entries: [PaletteEntry]
    var prompt = "Go to a favorite, server, drive or recent folder"
    /// Files the choice will act on, listed in full above the field (Send to
    /// Blit: another app named them, so you see exactly what you're sending).
    var items: [URL] = []
    let onSelect: (BrowseLocation) -> Void
    @State private var query = ""
    @State private var highlighted: PaletteEntry.ID?
    @FocusState private var fieldFocused: Bool
    @Environment(\.dismiss) private var dismiss

    private var results: [PaletteEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries
            .compactMap { entry -> (PaletteEntry, Int)? in
                if let s = Self.score(q, entry.name.lowercased()) { return (entry, s + 10) }
                if let s = Self.score(q, entry.detail.lowercased()) { return (entry, s) }
                return nil
            }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    /// Prefix beats substring beats in-order letters (so "mmov" finds Media › Movies).
    static func score(_ query: String, _ text: String) -> Int? {
        if text.hasPrefix(query) { return 3 }
        if text.contains(query) { return 2 }
        var remaining = query[...]
        for c in text where c == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return 1 }
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if !items.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(items, id: \.self) { url in
                            Text(url.path)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 110)
                Divider()
            }
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(prompt, text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($fieldFocused)
                    .onSubmit(openHighlighted)
                    .onKeyPress(.downArrow) { move(1); return .handled }
                    .onKeyPress(.upArrow) { move(-1); return .handled }
                    .onKeyPress(.escape) { dismiss(); return .handled }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                List(results, selection: $highlighted) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: entry.symbol).frame(width: 18).foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.name).lineLimit(1)
                            Text(entry.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(entry.group.rawValue).font(.caption).foregroundStyle(.tertiary)
                    }
                    .tag(entry.id)
                    .id(entry.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { select(entry) }
                }
                .listStyle(.plain)
                .onChange(of: highlighted) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
            .frame(height: 300)
            .overlay {
                if results.isEmpty { Text("No matches").foregroundStyle(.tertiary) }
            }
        }
        .frame(width: 520)
        .onAppear {
            fieldFocused = true
            highlighted = results.first?.id
        }
        .onChange(of: query) { highlighted = results.first?.id }
    }

    private func move(_ delta: Int) {
        let list = results
        guard !list.isEmpty else { return }
        let index = list.firstIndex { $0.id == highlighted } ?? -1
        highlighted = list[max(0, min(list.count - 1, index + delta))].id
    }

    private func openHighlighted() {
        if let entry = results.first(where: { $0.id == highlighted }) ?? results.first { select(entry) }
    }

    private func select(_ entry: PaletteEntry) {
        onSelect(entry.location)
        dismiss()
    }
}
