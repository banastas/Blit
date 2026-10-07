// Tabs of pairs (R2.18): each tab holds its own pair of panes, with their
// folders, history, sort, selection and scroll, and which side is active.
// Transfers stay global (the queue list shows them all on any tab), but each
// belongs to the tab it was started from: that tab's tag shows it while it
// runs, and the HUD follows it there.

import AppKit
import BlitLocal
import Foundation
import Observation

/// One tab: a pair of panes (the second is made when first shown).
@MainActor
@Observable
final class PaneTab: Identifiable {
    /// Kept across launches, so a restored transfer finds the tab it came from.
    let id: UUID
    let first: BrowserModel
    var second: BrowserModel?
    var secondActive = false
    /// A name the user gave the tab; nil follows the panes.
    var customName: String?
    /// Saved folders not opened yet (a restored tab opens its folders when it's
    /// first shown, so a sleeping NAS neither holds up the launch nor loses the
    /// tab's folder).
    @ObservationIgnored var pendingFirst: BrowseLocation?
    @ObservationIgnored var pendingSecond: BrowseLocation?
    /// Its folders have been asked for (opening waits a tick, and the window
    /// can show the tab twice before then).
    @ObservationIgnored var firstOpened = false
    @ObservationIgnored var secondOpened = false

    init(id: UUID = UUID(), first: BrowserModel, second: BrowserModel? = nil) {
        self.id = id
        self.first = first
        self.second = second
    }

    var firstLocation: BrowseLocation? { first.current ?? pendingFirst }
    var secondLocation: BrowseLocation? { second?.current ?? pendingSecond }
    /// The folders it shows: its second pane's only while the window shows two.
    var shownLocations: [BrowseLocation] {
        [firstLocation, Panes.shared.twoPanes ? secondLocation : nil].compactMap { $0 }
    }

    /// The tab's name: the user's, or the pair's folders.
    func title(twoPanes: Bool, servers: ServerStore) -> String {
        if let customName, !customName.isEmpty { return customName }
        let left = Self.name(of: firstLocation, servers: servers)
        guard twoPanes, let right = secondLocation.map({ Self.name(of: $0, servers: servers) }) else { return left }
        return "\(left) · \(right)"
    }

    static func name(of location: BrowseLocation?, servers: ServerStore) -> String {
        guard let location else { return "Blit" }
        if case .remote = location, location.lastComponent.isEmpty {
            return servers.server(location.serverID)?.displayName ?? "Server"
        }
        if case .local(let url) = location, url.path == "/" { return "Macintosh HD" }
        if case .local(let url) = location, let cloud = CloudFolders.folder(containing: url),
           cloud.url.path == url.lexicalPath { return cloud.name }
        return location.lastComponent
    }
}

/// The window's tabs, which one shows, and what they held last launch.
@MainActor
@Observable
final class PaneTabs {
    static let shared = PaneTabs()
    private static let key = "paneTabs"
    private static let selectedKey = "paneTabSelected"
    /// Where the tabs are saved: the app's defaults, and for a test copy
    /// nowhere, or a scratch suite of its own (-BlitTabsStore <suite>).
    private static let store: UserDefaults? = {
        if !TransferManager.isIsolated { return .standard }
        return UserDefaults.standard.string(forKey: "BlitTabsStore").flatMap(UserDefaults.init(suiteName:))
    }()

    private(set) var tabs: [PaneTab] = []
    private(set) var selectedID: UUID?
    /// The tab being renamed in the tab bar.
    var renamingID: UUID?

    /// Makes an empty pane (set by the window, which has the services).
    @ObservationIgnored var makeBrowser: (() -> BrowserModel)?

    var current: PaneTab? { tabs.first { $0.id == selectedID } ?? tabs.first }
    var selectedIndex: Int? { tabs.firstIndex { $0.id == current?.id } }

    /// Every pane in every tab (transfers refresh any that show a changed folder).
    var allBrowsers: [BrowserModel] { tabs.flatMap { [$0.first, $0.second].compactMap { $0 } } }

    /// The tab `model` is a pane of.
    func tab(of model: BrowserModel) -> PaneTab? {
        tabs.first { $0.first === model || $0.second === model }
    }

    // MARK: Changing tabs

    /// The first tab, from last launch's tabs if there were any.
    func startIfNeeded() {
        guard tabs.isEmpty, let makeBrowser else { return }
        let saved = Self.loadSaved()
        if saved.isEmpty {
            // Before tabs (0.2.22 and earlier): the two panes' folders.
            let tab = PaneTab(first: makeBrowser())
            tab.pendingFirst = TransferManager.isIsolated ? nil : PaneMemory.legacy(pane: 0)
            tab.pendingSecond = TransferManager.isIsolated ? nil : PaneMemory.legacy(pane: 1)
            tabs = [tab]
        } else {
            var ids = Set<UUID>()
            tabs = saved.map { entry in
                // Saved before 0.2.41 without one, or twice: a new id.
                let id = entry.id.flatMap { ids.insert($0).inserted ? $0 : nil } ?? UUID()
                let tab = PaneTab(id: id, first: makeBrowser())
                tab.pendingFirst = entry.first
                tab.pendingSecond = entry.second
                tab.secondActive = entry.secondActive
                tab.customName = entry.name
                return tab
            }
        }
        let index = Self.store?.integer(forKey: Self.selectedKey) ?? 0
        selectedID = tabs[min(max(index, 0), tabs.count - 1)].id
    }

    /// File › New Tab (⌘T): the same pair, beside the current tab.
    func newTab() {
        guard let makeBrowser, let source = current else { return }
        let tab = PaneTab(first: makeBrowser())
        tab.pendingFirst = source.firstLocation
        tab.pendingSecond = source.secondLocation
        tab.secondActive = source.secondActive
        tabs.insert(tab, at: (selectedIndex ?? tabs.count - 1) + 1)
        show(tab)
    }

    /// File › Close Tab (⌘W). The last tab stays (⌘W then closes the window).
    func close(_ id: UUID) {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[index]
        [closing.first, closing.second].compactMap { $0 }.forEach {
            $0.previewURL = nil
            $0.noteLeaving()
        }
        tabs.remove(at: index)
        if closing.id == selectedID { show(tabs[min(index, tabs.count - 1)]) } else { save() }
    }

    func closeOthers(than id: UUID) {
        guard let keep = tabs.first(where: { $0.id == id }) else { return }
        tabs = [keep]
        show(keep)
    }

    func select(_ id: UUID) {
        guard id != current?.id, let tab = tabs.first(where: { $0.id == id }) else { return }
        show(tab)
    }

    func select(index: Int) {
        guard tabs.indices.contains(index) else { return }
        select(tabs[index].id)
    }

    /// Window › Show Next / Previous Tab (⌃Tab, ⌃⇧Tab), wrapping around.
    func selectNext(_ step: Int) {
        guard tabs.count > 1, let index = selectedIndex else { return }
        select(index: (index + step + tabs.count) % tabs.count)
    }

    /// Drag in the tab bar.
    func move(_ id: UUID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let to = min(max(index, 0), tabs.count - 1)
        guard from != to else { return }
        tabs.insert(tabs.remove(at: from), at: to)
        save()
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs.first { $0.id == id }?.customName = trimmed.isEmpty ? nil : trimmed
        renamingID = nil
        save()
    }

    private func show(_ tab: PaneTab) {
        // The window opens a new or restored tab's folders as it shows it.
        selectedID = tab.id
        save()
    }

    #if DEBUG
    /// A tab with these folders at the end of the bar, not shown (the website's screenshot).
    func debugAppend(first: BrowseLocation, second: BrowseLocation, name: String? = nil) {
        guard let makeBrowser else { return }
        let tab = PaneTab(first: makeBrowser())
        tab.pendingFirst = first
        tab.pendingSecond = second
        tab.customName = name
        tabs.append(tab)
    }
    #endif

    // MARK: Saving

    private struct Saved: Codable {
        var id: UUID?
        var first: BrowseLocation?
        var second: BrowseLocation?
        var secondActive: Bool
        var name: String?
    }

    /// Saved at every change of folder or tab. Test copies never save to the
    /// app's defaults (they'd overwrite the user's tabs).
    func save() {
        guard let store = Self.store, !tabs.isEmpty else { return }
        let saved = tabs.map { Saved(id: $0.id, first: $0.firstLocation, second: $0.secondLocation,
                                     secondActive: $0.secondActive, name: $0.customName) }
        guard let data = try? JSONEncoder().encode(saved) else { return }
        store.set(data, forKey: Self.key)
        store.set(selectedIndex ?? 0, forKey: Self.selectedKey)
    }

    private static func loadSaved() -> [Saved] {
        guard let data = store?.data(forKey: key),
              let saved = try? JSONDecoder().decode([Saved].self, from: data) else { return [] }
        return saved
    }
}
