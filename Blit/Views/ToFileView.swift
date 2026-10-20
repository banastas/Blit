// To File (PRD R2.27): every download that landed and hasn't been filed, with
// what Blit would do with each, a key away: Space previews, R renames with the
// naming preset that fits, M moves to the suggested folder, ⌘⌫ moves to the
// Trash, F marks it filed, Return shows it in its folder. Each is the user's
// action; nothing happens by itself.

import AppKit
import SwiftUI

struct ToFileView: View {
    let browser: BrowserModel
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [ToFile.Row]?
    @State private var selection: String?
    @State private var previewURL: URL?
    /// Moves under way: an item's path → the folder it's going to.
    @State private var moving: [String: String] = [:]
    @State private var siblings: [String: [String]] = [:]
    @FocusState private var listFocused: Bool

    private var chosen: ToFile.Row? { rows?.first { $0.id == selection } ?? nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("To File").font(.headline)
                if let rows, !rows.isEmpty { Text("\(rows.count)").foregroundStyle(.secondary) }
                Spacer()
                Text("Space Quick Look · R Rename · M Move · ⌘⌫ Trash · F Filed · ↩ Show")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Group {
                if let rows {
                    if rows.isEmpty {
                        ContentUnavailableView("Nothing to File", systemImage: "tray",
                                               description: Text("Downloads show up here when they land, until they're moved off this drive, renamed into place or marked filed."))
                    } else {
                        List(rows, selection: $selection) { row in line(row).tag(row.id) }
                            .focused($listFocused)
                            .onKeyPress(.space) { togglePreview(); return .handled }
                            .onKeyPress(.return) { if let chosen { show(chosen) }; return .handled }
                            .onKeyPress(characters: CharacterSet(charactersIn: "rRmMfF")) { press in
                                guard let chosen else { return .ignored }
                                switch press.characters.lowercased() {
                                case "r": rename(chosen)
                                case "m": move(chosen)
                                default: filed(chosen)
                                }
                                return .handled
                            }
                            .contextMenu(forSelectionType: String.self) { ids in
                                if let row = rows.first(where: { ids.contains($0.id) }) {
                                    Button("Quick Look") { selection = row.id; togglePreview() }
                                    Button("Rename with Preset") { rename(row) }.disabled(preset(row) == nil)
                                    Button("Move to Suggested Folder") { move(row) }.disabled(suggestion(row) == nil)
                                    Button("Move to Trash") { trash(row) }
                                    Button("Mark as Filed") { filed(row) }
                                    Divider()
                                    Button("Show in Folder") { show(row) }
                                }
                            } primaryAction: { ids in
                                if let row = rows.first(where: { ids.contains($0.id) }) { show(row) }
                            }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                Button("Rename") { if let chosen { rename(chosen) } }.disabled(chosen.flatMap(preset) == nil)
                Button("Move") { if let chosen { move(chosen) } }.disabled(chosen.flatMap(suggestion) == nil)
                Button("Move to Trash") { if let chosen { trash(chosen) } }
                    .keyboardShortcut(.delete, modifiers: .command)
                    .disabled(chosen == nil)
                Button("Mark as Filed") { if let chosen { filed(chosen) } }.disabled(chosen == nil)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 520)
        .quickLookPreview($previewURL)
        .task {
            // Kept current while it's up: moves finish, the Trash takes things.
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func line(_ row: ToFile.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: row.item.isDirectory ? "folder" : "doc").foregroundStyle(.secondary)
                Text(row.item.name).lineLimit(1).truncationMode(.middle)
            }
            Text(placeLine(row)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            let plan = plans(row)
            if !plan.isEmpty {
                Text(plan).font(.caption).foregroundStyle(moving[row.id] == nil ? .primary : .secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    private func placeLine(_ row: ToFile.Row) -> String {
        let folder = (row.entry.path as NSString).deletingLastPathComponent
        let parts = folder.split(separator: "/").map(String.init)
        let shown = (parts.first == "Volumes" ? Array(parts.dropFirst()) : parts).suffix(3).joined(separator: " › ")
        var text = "\(shown) · arrived \(row.entry.arrived.formatted(.relative(presentation: .named)))"
        if row.item.size >= 0 { text += " · \(row.item.size.formatted(.byteCount(style: .file)))" }
        return text
    }

    /// "Rename → Get-Jiro_S01E02.mkv · Move to Season 1 — Get Jiro", or that it's moving.
    private func plans(_ row: ToFile.Row) -> String {
        if let target = moving[row.id] { return "Moving to \((target as NSString).lastPathComponent)…" }
        var parts: [String] = []
        if let preset = preset(row) { parts.append("R → \(preset.row.newName)") }
        if let suggestion = suggestion(row) { parts.append("M → \(suggestion.title)") }
        return parts.joined(separator: " · ")
    }

    private func preset(_ row: ToFile.Row) -> (preset: RenamePreset, row: RenamePlanRow)? {
        ToFile.preset(for: row.item) { folder in siblings[folder.localURL?.path ?? ""] ?? [] }
    }

    private func suggestion(_ row: ToFile.Row) -> DestinationMemory.Suggestion? {
        DestinationMemory.shared.suggestions(for: [row.item]).first
    }

    // MARK: Actions

    private func refresh() async {
        await ToFile.shared.prune()
        let found = await ToFile.shared.rows()
        let folders = Set(found.map { ($0.entry.path as NSString).deletingLastPathComponent })
        siblings = await Task.detached {
            Dictionary(uniqueKeysWithValues: folders.map { ($0, (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? []) })
        }.value
        // A move into a folder on this drive is a rename: it's filed once it's there.
        let arrived = found.filter { row in moving.values.contains { row.entry.path.hasPrefix($0 + "/") } }
        if !arrived.isEmpty { ToFile.shared.remove(Set(arrived.map(\.entry.path))) }
        moving = moving.filter { path, _ in found.contains { $0.entry.path == path } }
        rows = found.filter { row in !arrived.contains { $0.id == row.id } }
        if selection == nil || !(rows ?? []).contains(where: { $0.id == selection }) { selection = rows?.first?.id }
        if rows?.isEmpty == false { listFocused = true }
    }

    private func togglePreview() {
        guard let chosen else { return }
        let url = URL(fileURLWithPath: chosen.entry.path)
        previewURL = previewURL == url ? nil : url
    }

    private func rename(_ row: ToFile.Row) {
        guard let plan = preset(row) else { return }
        browser.commitBatchRename([plan.row])
        Task { try? await Task.sleep(for: .milliseconds(400)); await refresh() }
    }

    private func move(_ row: ToFile.Row) {
        guard let suggestion = suggestion(row), let folder = suggestion.folder.localURL else { return }
        moving[row.id] = folder.path
        browser.send([row.item], to: suggestion, move: true)
    }

    private func trash(_ row: ToFile.Row) {
        Task {
            if let problem = await browser.operations.moveToTrash([row.item.location]) { browser.report(problem, action: "MOVE TO TRASH") }
            await refresh()
        }
    }

    private func filed(_ row: ToFile.Row) {
        ToFile.shared.remove([row.entry.path])
        rows?.removeAll { $0.id == row.id }
        selection = rows?.first?.id
    }

    /// Its folder in the active pane, with it selected.
    private func show(_ row: ToFile.Row) {
        dismiss()
        let browser = browser
        let url = URL(fileURLWithPath: row.entry.path)
        Task {
            let folder = url.deletingLastPathComponent()
            if browser.current?.localURL?.lexicalPath != folder.lexicalPath { browser.open(.local(folder)) }
            for _ in 0..<50 {
                if let item = browser.rows.first(where: { $0.depth == 0 && $0.name == url.lastPathComponent }) {
                    browser.selection = [item.id]
                    browser.requestKeyboardFocus()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

/// Go › To File…: a view of its own, so its count follows the list.
struct ToFileMenuItem: View {
    let open: () -> Void
    var body: some View {
        let count = ToFile.shared.entries.count
        Button(count == 0 ? "To File…" : "To File (\(count))…", action: open)
            .keyboardShortcut("j", modifiers: [.command, .shift])
    }
}
