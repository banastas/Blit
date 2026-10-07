// Watch mode's views (PRD R5.10): setting up a watch on a server folder, and
// Settings › Watch, where watches are switched on and off, timed and removed.

import AppKit
import SwiftUI

/// "Watch “completed” for New Downloads": where new items go, and how often to look.
struct WatchSetupView: View {
    let source: BrowseLocation
    let browser: BrowserModel
    @Environment(SeedboxWatch.self) private var watch
    @Environment(\.dismiss) private var dismiss
    @State private var destination: URL?
    @State private var minutes = 2

    /// The other pane's folder (if it's on this Mac), then the favorites on this Mac.
    private var choices: [(name: String, url: URL)] {
        var list: [(name: String, url: URL)] = []
        if let other = BrowserModel.oppositePane?(browser), let url = other.current?.localURL {
            list.append(("\(url.lastPathComponent) (the other pane)", url))
        }
        for place in BrowserModel.destinations() {
            guard let url = place.location.localURL, !list.contains(where: { $0.url.lexicalPath == url.lexicalPath }) else { continue }
            list.append((place.detail.map { "\(place.name) — \($0)" } ?? place.name, url))
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Watch “\(source.lastComponent.isEmpty ? "Home" : source.lastComponent)” for New Downloads").font(.headline)
            Text("Blit looks here every few minutes and downloads what's new to a folder on this Mac, while it's still in the server's cache. If qBittorrent runs on the server, Blit reads its own records and fetches a torrent only once qBittorrent has finished it, so a stalled one waits however quiet it is. Anything else waits until it has stopped changing for two minutes and has no partial files in it. What's here now isn't fetched; nothing is ever deleted from the server.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("With another torrent client, best pointed at the folder it moves finished downloads into.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Form {
                Picker("Download to", selection: $destination) {
                    if destination == nil { Text("Choose…").tag(URL?.none) }
                    ForEach(choices, id: \.url) { choice in Text(choice.name).tag(URL?.some(choice.url)) }
                    if let destination, !choices.contains(where: { $0.url == destination }) {
                        Text(destination.lastPathComponent).tag(URL?.some(destination))
                    }
                }
                Button("Other Folder…") { chooseFolder() }
                Picker("Look every", selection: $minutes) {
                    ForEach([1, 2, 5, 15], id: \.self) { Text("\($0) minute\($0 == 1 ? "" : "s")").tag($0) }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start Watching") {
                    guard let destination else { return }
                    watch.add(WatchRule(source: source, destination: destination.path, minutes: minutes))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(destination == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { if destination == nil { destination = choices.first?.url } }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Download Here"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        destination = url
    }
}

/// Settings › Watch: every watch, switched on or off, with when it last looked
/// and what it last fetched (or what's wrong).
struct WatchSettingsSection: View {
    var body: some View {
        if let watch = SeedboxWatch.shared {
            if watch.rules.isEmpty {
                Text("Right-click a folder on a server (or empty space in one) and choose Watch for New Downloads… to have Blit fetch what's new there.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(watch.rules) { rule in
                    WatchRow(watch: watch, rule: rule)
                }
            }
            Text("Watches fetch from servers to this Mac only, as verified copies; the server keeps seeding. What goes on to a NAS stays your call.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct WatchRow: View {
    let watch: SeedboxWatch
    let rule: WatchRule

    var body: some View {
        let state = watch.states[rule.id]
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: Binding(get: { rule.enabled }, set: { watch.setEnabled(rule.id, $0) })) {
                    Text("\(watch.title(of: rule)) → \(URL(fileURLWithPath: rule.destination).lastPathComponent)")
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Picker("", selection: Binding(get: { rule.minutes }, set: { watch.setMinutes(rule.id, $0) })) {
                    ForEach([1, 2, 5, 15], id: \.self) { Text("every \($0) min").tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                Button("Remove") { watch.remove(rule.id) }
            }
            Group {
                if let problem = state?.problem {
                    Text(problem).foregroundStyle(Color.failureText)
                } else if let state, let last = state.lastCheck {
                    let waiting = state.pending.count, downloading = state.downloading.count
                    Text("Looked \(last.formatted(.relative(presentation: .named)))"
                         + (state.records != nil ? " · reading qBittorrent's records" : "")
                         + (downloading > 0 ? " · \(downloading) still downloading in qBittorrent" : "")
                         + (waiting > 0 ? " · \(waiting) new, waiting to settle" : "")
                         + (state.lastFetched.map { " · last fetched “\($0)”" } ?? ""))
                        .foregroundStyle(.secondary)
                } else {
                    Text(rule.enabled ? "Not looked yet" : "Off").foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .lineLimit(2)
        }
    }
}
