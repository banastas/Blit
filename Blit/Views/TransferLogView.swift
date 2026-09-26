// Window › Transfer Log (⌥⌘L, PRD R4.4): every file Blit has transferred,
// newest first, searchable, with how each was verified, its SHA-256 and its
// source: a per-file answer to "was this one checked?".

import AppKit
import SwiftUI

struct LogEntry: Identifiable, Hashable {
    let id: Int
    let record: TransferRecord

    var name: String { (record.destination as NSString).lastPathComponent }
    var folder: String { ((record.destination as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath }
    var failed: Bool { record.result != "ok" }
    var hashVerified: Bool {
        !failed && ["server-sha256", "nas-sha256", "read-back", "present-sha256"].contains(record.verification)
    }

    var method: String {
        if failed { return "Failed" }
        return switch record.verification {
        case "server-sha256": "SHA-256 · server"
        case "nas-sha256": "SHA-256 · NAS"
        case "read-back": "SHA-256 · read-back"
        case "present-sha256": "Already there · SHA-256"
        case "size-only": "Size only"
        case "already-present": "Already there · size"
        case "cloned": "Cloned (same volume)"
        default: "Not verified"
        }
    }

    static func == (a: LogEntry, b: LogEntry) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct TransferLogView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", verified = "Verified", unverified = "Not hash-verified", failed = "Failed"
        var id: Self { self }
    }

    @State private var entries: [LogEntry] = []
    @State private var search = ""
    @State private var filter = Filter.all
    @State private var selection: LogEntry.ID?
    @State private var sortOrder = [KeyPathComparator(\LogEntry.record.time, order: .reverse)]

    private var shown: [LogEntry] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { entry in
            switch filter {
            case .all: break
            case .verified: if !entry.hashVerified { return false }
            case .unverified: if entry.hashVerified || entry.failed { return false }
            case .failed: if !entry.failed { return false }
            }
            guard !query.isEmpty else { return true }
            return entry.record.destination.lowercased().contains(query)
                || entry.record.source.lowercased().contains(query)
                || (entry.record.sha256?.hasPrefix(query) ?? false)
        }.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(shown, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("") { entry in
                    Image(nsImage: (entry.failed ? PixelGlyph.cross : entry.hashVerified ? PixelGlyph.check : PixelGlyph.arrow)
                        .image(size: 10))
                        .foregroundStyle(entry.failed ? Color.failure : entry.hashVerified ? .primary : .secondary)
                        .help(entry.method)
                }
                .width(16)
                TableColumn("Time", value: \.record.time) { entry in
                    Text(entry.record.time, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 150)
                TableColumn("Name", value: \.name) { entry in Text(entry.name).lineLimit(1) }
                    .width(min: 160, ideal: 320)
                TableColumn("Verification", value: \.method) { entry in
                    Text(entry.method).foregroundStyle(entry.failed ? Color.failure : .secondary)
                }
                .width(min: 110, ideal: 160)
                TableColumn("Size", value: \.record.size) { entry in
                    Text(Int64(entry.record.size).formatted(.byteCount(style: .file)))
                        .monospacedDigit().foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 60, ideal: 80)
                TableColumn("Destination", value: \.folder) { entry in
                    Text(entry.folder).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                }
                .width(min: 120, ideal: 260)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            if let entry = entries.first(where: { $0.id == selection }) {
                Divider()
                detail(entry)
            }
        }
        .searchable(text: $search, prompt: "Name, path or SHA-256")
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem {
                Button("Export CSV…", systemImage: "square.and.arrow.up") { TransferLog.export() }
                    .help("Export the whole log as CSV")
            }
        }
        .navigationTitle("Transfer Log")
        .navigationSubtitle("\(shown.count) of \(entries.count) files")
        .frame(minWidth: 760, minHeight: 360)
        .task { await reload() }
        .onReceive(NotificationCenter.default.publisher(for: TransferLog.didAppend)) { _ in
            Task { await reload() }
        }
    }

    @ViewBuilder private func detail(_ entry: LogEntry) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                Text("Destination").foregroundStyle(.secondary)
                Text(entry.record.destination).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            }
            GridRow {
                Text("Source").foregroundStyle(.secondary)
                Text(entry.record.source).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
            }
            if let sha = entry.record.sha256 {
                GridRow {
                    Text("SHA-256").foregroundStyle(.secondary)
                    Text(sha).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
            }
            if let detail = entry.record.detail {
                GridRow {
                    Text("Detail").foregroundStyle(.secondary)
                    Text(detail).textSelection(.enabled).foregroundStyle(entry.failed ? Color.failure : .primary)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        HStack {
            if FileManager.default.fileExists(atPath: entry.record.destination) {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.record.destination)])
                }
            }
            if let sha = entry.record.sha256 {
                Button("Copy SHA-256") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(sha, forType: .string)
                }
            }
            Spacer()
        }
        .padding([.horizontal, .bottom], 12)
    }

    private func reload() async {
        let url = TransferLog.url
        let records = await Task.detached { TransferLog.readRecords(at: url) }.value
        entries = records.enumerated().map { LogEntry(id: $0.offset, record: $0.element) }
    }
}
