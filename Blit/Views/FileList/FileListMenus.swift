// The AppKit file list's context menus (PRD R2.12, R2.17): for the row
// clicked (or the selection, when the click was inside it) and for empty
// space, the items the SwiftUI list had (until 0.2.41). Built as the menu opens; the
// items hold the model and the rows they act on, never the list.

import AppKit

@MainActor
enum FileMenuBuilder {
    /// Empty space: the folder's own menu.
    static func folderItems(in browser: BrowserModel) -> [NSMenuItem] {
        var menu: [NSMenuItem] = []
        menu.append(action("New Folder") { browser.newFolder() })
        menu.append(.separator())
        menu.append(action("Paste", enabled: browser.operations.canPaste) { browser.paste(move: false) })
        menu.append(.separator())
        menu.append(action("Refresh") { browser.reload() })
        return menu
    }

    /// The menu for `items` (one row, or the selection).
    static func items(for items: [FileItem], in browser: BrowserModel) -> [NSMenuItem] {
        var menu: [NSMenuItem] = []
        let urls = items.compactMap(\.location.localURL)
        let allLocal = !urls.isEmpty && urls.count == items.count
        if items.count == 1, items[0].isDirectory {
            menu.append(action("Open") { browser.open(items[0].location) })   // browses into it here
        } else if allLocal, !items.contains(where: \.isDirectory) {
            menu.append(action("Open") { for url in urls { NSWorkspace.shared.open(url) } })   // each in its default app
        }
        if allLocal { menu.append(openWith(urls, browser: browser)) }
        menu.append(action("Quick Look") {
            browser.selection = Set(items.map(\.id))
            browser.previewURL = nil
            browser.previewSelection()
        })
        if !urls.isEmpty { menu.append(action("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(urls) }) }
        if items.count == 1 { menu.append(action("Get Info") { browser.infoItem = items[0] }) }
        if items.count == 1, items[0].partial != nil {
            menu.append(.separator())
            let problem = browser.resumeProblem(items[0])
            menu.append(action("Resume Download", enabled: problem == nil,
                               help: problem ?? "Download the rest of this file into this folder.") { browser.resumeDownload(items[0]) })
        }
        // In its own section, after the item's details and before the edits.
        menu.append(.separator())
        menu.append(action(browser.deleteTitle(for: items)) { browser.requestDelete(items) })
        menu.append(.separator())
        menu.append(action("New Folder") { browser.newFolder() })
        // Several items in one folder: into a new folder of their own, as in Finder.
        if browser.canMakeFolder(with: items) {
            menu.append(action("New Folder with Selection (\(items.count) Items)") { browser.newFolder(with: items) })
        }
        menu.append(action(items.count == 1 ? "Rename" : "Rename \(items.count) Items…") { browser.beginRename(items) })
        if let presets = presetsMenu(items, browser: browser) { menu.append(presets) }
        menu += sendMenus(items, browser: browser)
        // The other pane of a two-pane window (F5 / F6 from the keyboard).
        if let other = BrowserModel.oppositePane?(browser), let there = other.current, there != browser.current {
            menu.append(action("Copy to “\(other.title)”") { browser.send(items, to: there, name: other.title, move: false) })
            menu.append(action("Move to “\(other.title)”") { browser.send(items, to: there, name: other.title, move: true) })
            if items.count == 1, items[0].isDirectory {
                menu.append(action("Open in Other Pane") { other.open(items[0].location) })
            }
        }
        // Where items like these went last (⇧F6 from the keyboard).
        if let suggestion = DestinationMemory.shared.suggestions(for: items).first {
            let item = action("Move to “\(suggestion.name)”", help: suggestion.reason + (suggestion.mayBeNew ? " (made as it's moved, if it isn't there yet)" : "")) {
                browser.send(items, to: suggestion, move: true)
            }
            item.image = NSImage(systemSymbolName: "clock.arrow.circlepath", accessibilityDescription: "Suggested")
            menu.append(item)
        }
        if urls.count == items.count { menu.append(action("Duplicate") { browser.duplicate(items) }) }
        menu.append(.separator())
        menu.append(action("Cut") { browser.copy(items, cut: true) })
        menu.append(action("Copy") { browser.copy(items, cut: false) })
        menu.append(action("Paste", enabled: browser.operations.canPaste) { browser.paste(move: false) })
        menu.append(.separator())
        menu.append(action("Refresh") { browser.reload() })
        return menu
    }

    private static func action(_ title: String, enabled: Bool = true, help: String? = nil,
                               _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title, handler: handler)
        item.isEnabled = enabled
        item.toolTip = help
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        menu.autoenablesItems = false
        items.forEach(menu.addItem)
        item.submenu = menu
        return item
    }

    /// Rename With Preset ▸: each naming preset (Rename N Items keeps them),
    /// titled with what it would do: the new name for one item, how many
    /// change for several (each old and new name in its help tag). Applied as
    /// one rename, one step to undo; a preset that changes nothing is off.
    private static func presetsMenu(_ items: [FileItem], browser: BrowserModel) -> NSMenuItem? {
        let presets = RenamePresets.all()
        guard !presets.isEmpty else { return nil }
        var entries: [NSMenuItem] = []
        for preset in presets {
            let rows = RenamePlan.rows(items, steps: preset.steps, siblings: browser.names(in:))
            let renamed = rows.filter { $0.changes && $0.problem == nil }
            let title: String
            if items.count == 1, let row = rows.first {
                if let problem = row.problem, row.changes {
                    title = "\(preset.name) → \(shortened(row.newName)) (\(problem))"
                } else {
                    title = row.changes ? "\(preset.name) → \(shortened(row.newName))" : "\(preset.name) — no change"
                }
            } else {
                title = renamed.isEmpty ? "\(preset.name) — no change" : "\(preset.name) — \(renamed.count) of \(items.count) renamed"
            }
            let changes = rows.filter(\.changes).prefix(8).map { row in
                "\(row.item.name) → \(row.newName)\(row.problem.map { " (\($0))" } ?? "")"
            }
            entries.append(action(title, enabled: !renamed.isEmpty, help: changes.isEmpty ? nil : changes.joined(separator: "\n")) {
                browser.commitBatchRename(renamed)
            })
        }
        entries.append(.separator())
        entries.append(action("Edit Presets…") { browser.batchRenameItems = items })
        return submenu("Rename With Preset", entries)
    }

    /// A long name shortened in the middle, for a menu title.
    private static func shortened(_ name: String, to limit: Int = 60) -> String {
        guard name.count > limit else { return name }
        return name.prefix(limit / 2 - 1) + "…" + name.suffix(limit / 2)
    }

    /// Open With ▸: the default app first, then every other app that opens
    /// them all, then Other…, each with its icon (as Finder shows them).
    private static func openWith(_ urls: [URL], browser: BrowserModel) -> NSMenuItem {
        let apps = OpenWith.apps(for: urls)
        let report: @MainActor (String) -> Void = { [weak browser] in browser?.report($0, action: "OPEN") }
        func app(_ app: OpenWith.App, title: String) -> NSMenuItem {
            let item = action(title) { OpenWith.open(urls, with: app.url, onProblem: report) }
            item.image = app.icon
            return item
        }
        var items: [NSMenuItem] = []
        if let primary = apps.primary {
            items.append(app(primary, title: "\(primary.name) (default)"))
            if !apps.others.isEmpty { items.append(.separator()) }
        }
        items += apps.others.map { app($0, title: $0.name) }
        items.append(.separator())
        items.append(action("Other…") { OpenWith.chooseApp(for: urls, onProblem: report) })
        return submenu("Open With", items)
    }

    /// Copy To ▸ and Move To ▸: suggested folders (where items like these went
    /// last), the sidebar's favorites (NAS folders first) and Other Folder…,
    /// for archiving reviewed items without dragging.
    private static func sendMenus(_ items: [FileItem], browser: BrowserModel) -> [NSMenuItem] {
        let parents = Set(items.compactMap(\.location.parent))
        let places = BrowserModel.destinations().filter { !parents.contains($0.location) }
        let suggestions = DestinationMemory.shared.suggestions(for: items)
        return [false, true].map { move in
            var entries: [NSMenuItem] = []
            if !suggestions.isEmpty {
                entries.append(.sectionHeader(title: "Suggested"))
                for suggestion in suggestions {
                    entries.append(action(suggestion.title, help: suggestion.reason + (suggestion.mayBeNew ? " (made as it's moved, if it isn't there yet)" : "")) {
                        browser.send(items, to: suggestion, move: move)
                    })
                }
                entries.append(.separator())
            }
            entries += places.map { place in
                action(place.detail.map { "\(place.name) — \($0)" } ?? place.name) {
                    browser.send(items, to: place.location, name: place.name, move: move)
                }
            }
            if !places.isEmpty { entries.append(.separator()) }
            entries.append(action("Other Folder…") { browser.sendToChosenFolder(items, move: move) })
            let item = submenu(move ? "Move To" : "Copy To", entries)
            item.toolTip = move ? "Each file is removed from here once its copy is verified by SHA-256" : "A verified copy"
            return item
        }
    }
}
