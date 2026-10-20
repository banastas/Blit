// Find in Archive (PRD R4.6): search everything Blit has moved, by any name it
// had, and go to where it is now. From Blit's own log, so the NAS can be asleep.

import AppKit
import SwiftUI

struct ArchiveSearchView: View {
    let browser: BrowserModel
    /// What's in the search field at first (tests).
    var initialQuery = ""
    @Environment(\.dismiss) private var dismiss
    @State private var items: [ArchiveItem]?
    @State private var query = ""
    @State private var selection: ArchiveItem.ID?
    @FocusState private var searching: Bool

    private var results: [ArchiveItem] { items.map { ArchiveIndex.search(query, in: $0) } ?? [] }
    private var chosen: ArchiveItem? { results.first { $0.id == selection } ?? results.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find in Archive").font(.headline)
            TextField("A file's name, any name it had, or its folder", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searching)
                .onSubmit { if let chosen { show(chosen) } }
            Group {
                if let items {
                    if query.trimmingCharacters(in: .whitespaces).isEmpty {
                        Text("Everything Blit has moved: \(items.count.formatted()) files, each where Blit put it last. Found from Blit's own log, so a NAS can be asleep.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    } else if results.isEmpty {
                        ContentUnavailableView.search(text: query)
                    } else {
                        List(results, selection: $selection) { item in row(item).tag(item.id) }
                            .contextMenu(forSelectionType: ArchiveItem.ID.self) { ids in
                                if let item = results.first(where: { ids.contains($0.id) }) {
                                    Button("Show in Blit") { show(item) }
                                    Button("Show in Finder") { reveal(item) }
                                }
                            } primaryAction: { ids in
                                if let item = results.first(where: { ids.contains($0.id) }) { show(item) }
                            }
                    }
                } else {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading Blit's log…").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
            HStack {
                if !results.isEmpty {
                    Text(results.count == 200 ? "The newest 200" : "\(results.count) found").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show in Finder") { if let chosen { reveal(chosen) } }
                    .disabled(chosen == nil)
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Show in Blit") { if let chosen { show(chosen) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen == nil)
            }
        }
        .padding(20)
        .frame(width: 660, height: 500)
        .task {
            searching = true
            if query.isEmpty { query = initialQuery }
            let log = TransferLog.url
            items = await Task.detached(priority: .userInitiated) { ArchiveIndex.load(log) }.value
        }
    }

    private func row(_ item: ArchiveItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.name).lineLimit(1).truncationMode(.middle)
            Text(placeLine(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
            if let first = item.names.first, first != item.name {
                Text("was “\(first)”").font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
        .help(([item.location] + item.earlier.reversed().map { "before: " + $0 }).joined(separator: "\n"))
    }

    /// "Files › TV Shows › Get Jiro · Oct 18, 2026 · 1.2 GB · verified"
    private func placeLine(_ item: ArchiveItem) -> String {
        let folders = item.folder.split(separator: "/").map(String.init)
        let inVolume = folders.first == "Volumes" ? Array(folders.dropFirst(2)) : folders
        let path = ([ArchiveIndex.volumeName(item.folder)] + inVolume.suffix(3)).joined(separator: " › ")
        var parts = [path, item.time.formatted(date: .abbreviated, time: .omitted), Int64(item.size).formatted(.byteCount(style: .file))]
        if item.verified { parts.append("verified") }
        return parts.joined(separator: " · ")
    }

    /// The file selected in its folder, in the active pane.
    private func show(_ item: ArchiveItem) {
        dismiss()
        let browser = browser
        Task {
            let there = await Task.detached { FileManager.default.fileExists(atPath: item.location) }.value
            guard there else { return missing(item) }
            let folder = URL(fileURLWithPath: item.folder, isDirectory: true)
            if browser.current?.localURL?.lexicalPath != folder.lexicalPath { browser.open(.local(folder)) }
            for _ in 0..<50 {
                if let row = browser.rows.first(where: { $0.depth == 0 && $0.name == item.name }) {
                    browser.selection = [row.id]
                    browser.requestKeyboardFocus()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func reveal(_ item: ArchiveItem) {
        Task {
            let there = await Task.detached { FileManager.default.fileExists(atPath: item.location) }.value
            guard there else { return missing(item) }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.location)])
        }
    }

    private func missing(_ item: ArchiveItem) {
        browser.report("“\(item.name)” isn't where Blit put it (\(item.folder)): its drive or share may not be connected, or it was moved or renamed outside Blit.",
                       action: "FIND IN ARCHIVE")
    }
}
