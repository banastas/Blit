// Right-click › Open With, as in Finder: the default app first, then every
// other app that can open all the selected items, then Other… to pick any
// app. Local files only (a server's file would have to be downloaded first).
// The file list's menu (FileList/FileListMenus.swift) lists them.

import AppKit
import UniformTypeIdentifiers

enum OpenWith {
    struct App: Identifiable {
        let url: URL
        let name: String
        let icon: NSImage
        var id: URL { url }
    }

    /// The default app for every item (nil when they differ), and the others
    /// that can open them all, by name.
    @MainActor
    static func apps(for urls: [URL]) -> (primary: App?, others: [App]) {
        let workspace = NSWorkspace.shared
        guard let first = urls.first else { return (nil, []) }
        let defaults = Set(urls.compactMap { workspace.urlForApplication(toOpen: $0)?.standardizedFileURL })
        let primaryURL = defaults.count == 1 && urls.allSatisfy({ workspace.urlForApplication(toOpen: $0) != nil })
            ? defaults.first : nil
        var common = Set(workspace.urlsForApplications(toOpen: first).map(\.standardizedFileURL))
        for url in urls.dropFirst() {
            common.formIntersection(workspace.urlsForApplications(toOpen: url).map(\.standardizedFileURL))
        }
        if let primaryURL { common.remove(primaryURL) }
        let others = common.map(app).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        // Two copies of one app (say, a beta): tell them apart by version.
        let names = Dictionary(grouping: others, by: \.name)
        let labelled = others.map { app -> App in
            guard (names[app.name]?.count ?? 0) > 1 else { return app }
            let version = Bundle(url: app.url)?.infoDictionary?["CFBundleShortVersionString"] as? String
            return App(url: app.url, name: "\(app.name) (\(version ?? app.url.deletingLastPathComponent().path))", icon: app.icon)
        }
        return (primaryURL.map(app), labelled)
    }

    @MainActor
    private static func app(_ url: URL) -> App {
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 16, height: 16)
        return App(url: url, name: name, icon: icon)
    }

    /// Opens `urls` in `app`; `onProblem` gets a message if it can't.
    @MainActor
    static func open(_ urls: [URL], with app: URL, onProblem: @escaping @MainActor (String) -> Void) {
        let name = FileManager.default.displayName(atPath: app.path)
        NSWorkspace.shared.open(urls, withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            let message = "\(name) couldn't open \(urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items"): \(error.localizedDescription)"
            Task { @MainActor in onProblem(message) }
        }
    }

    /// Other…: pick any app from Applications.
    @MainActor
    static func chooseApp(for urls: [URL], onProblem: @escaping @MainActor (String) -> Void) {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = urls.count == 1 ? "Choose an app to open “\(urls[0].lastPathComponent)”." : "Choose an app to open \(urls.count) items."
        guard panel.runModal() == .OK, let app = panel.url else { return }
        open(urls, with: app, onProblem: onProblem)
    }
}
