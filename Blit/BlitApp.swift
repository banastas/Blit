// Blit — a native macOS utility that moves big files fast and verifies every byte.

import AppIntents
import AppKit
import MediaToolbox
import Quartz
import SwiftUI
import VideoToolbox

/// Quitting mid-transfer: save the queue, close connections, then exit. A
/// short watchdog guarantees the process ends even if something still holds
/// it open; resume data (queue.json, .blitpart state) is already on disk.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var transfers: TransferManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Media Extensions (macOS 15+) teach AVFoundation new containers and
        // codecs: QuickLook Video's make MKV, WebM and AVI play. Apps must opt
        // in, and Quick Look plays video inside the app showing the panel, so
        // without this Space in Blit can't play what Finder can.
        MTRegisterProfessionalVideoWorkflowFormatReaders()
        VTRegisterProfessionalVideoWorkflowVideoDecoders()
        // One browser window: keyboard routing (Space, Return, file commands)
        // follows the window's active pane, so no second window or tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
        BrowserModel.cleanUpPreviewDownloads()
        _ = Updates.shared   // starts the daily update check (release builds)
        NSApp.servicesProvider = self
        TransferNotifications.register()
        NSUpdateDynamicServices()
        #if DEBUG
        UITestHarness.runIfRequested()
        UITestHarness.renderStatusIconsIfRequested()
        UITestHarness.renderMenuBarIfRequested()
        UITestHarness.runUndoTestIfRequested()
        UITestHarness.runPartialTestIfRequested()
        UITestHarness.runSortTestIfRequested()
        UITestHarness.renderPathBarIfRequested()
        UITestHarness.renderSettingsIfRequested()
        UITestHarness.runRenameFieldTestIfRequested()
        UITestHarness.renderInfoIfRequested()
        UITestHarness.runLogWindowTestIfRequested()
        #endif
        // Quick Look keys, as in Finder (PRD R2.17): Space opens and closes the
        // panel; while it's open, ↑/↓ preview the previous or next file. Left
        // alone while a text field or a sheet has the keyboard.
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let key = event.keyCode
            let space: UInt16 = 49, down: UInt16 = 125, up: UInt16 = 126, returnKey: UInt16 = 36, enter: UInt16 = 76
            let escape: UInt16 = 53
            guard [space, down, up, returnKey, enter, escape].contains(key),
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty,
                  key != space || !event.isARepeat else { return event }
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let window = NSApp.keyWindow else { return false }
                let panelIsKey = window is QLPreviewPanel
                // The pane whose list has the keyboard (that also makes this a
                // browser window); else the window's active pane. With the panel
                // key, the pane it previews. Space once went nowhere while the
                // remembered pane or window had gone stale (2026-10-18).
                let list = (window.firstResponder as? FileTableView)?.coordinator?.model
                let target = panelIsKey ? PaneTabs.shared.allBrowsers.first { $0.previewURL != nil } ?? BrowserModel.active
                    : list ?? BrowserModel.active
                guard let browser = target else { return KeyLog.ignored(key, "no active pane") }
                guard browser.current != nil else { return KeyLog.ignored(key, "the pane shows no folder") }
                if !panelIsKey {
                    guard list != nil || window === BrowserModel.activeWindow else { return KeyLog.ignored(key, "not a browser window") }
                    guard window.attachedSheet == nil else { return KeyLog.ignored(key, "a sheet is up") }
                    guard !(window.firstResponder is NSText) else { return false }   // typing
                }
                // Mid-rename (including the moment before the field takes the keyboard),
                // Space and Return belong to the name being edited.
                guard browser.renaming == nil else { return KeyLog.ignored(key, "a rename is in progress") }
                if key == escape {
                    // Escape closes what's open over the list: Quick Look, then the full HUD.
                    guard !panelIsKey else { return false }   // the panel closes itself
                    if browser.previewURL != nil || browser.previewLoading != nil {
                        browser.togglePreview()
                        return true
                    }
                    guard let transfers = self.transfers, transfers.isExpanded else { return false }
                    transfers.collapse()
                    return true
                }
                if key == returnKey || key == enter {
                    // Return renames the selection in place, as in Finder (⌘↓ or double-click opens).
                    guard !panelIsKey, browser.selection.count == 1,
                          let item = browser.selectedItems.first else { return false }
                    browser.beginRename(item)
                    return true
                }
                if key == space {
                    browser.togglePreview()
                    return true
                }
                guard browser.previewURL != nil else { return false }
                browser.movePreview(by: key == down ? 1 : -1)
                return true
            }
            return handled ? nil : event
        }
    }

    /// Finder › Services › Send to Blit…: bring Blit forward and ask where to copy.
    @objc func sendToBlit(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return }
        transfers?.pendingExternalFiles = urls
        NSApp.activate()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let transfers, transfers.hasActiveWork else { return .terminateNow }
        Task { @MainActor in
            await transfers.prepareForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        UserDefaults.standard.synchronize()
        MainActor.assumeIsolated {
            BrowserModel.cleanUpPreviewDownloads()
            // Every pane's folder is being left: what's in it now isn't new next time.
            PaneTabs.shared.allBrowsers.forEach { $0.noteLeaving() }
            FolderVisits.saveNow()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { _exit(0) }
    }
}

@main
struct BlitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var sidebar = SidebarModel()
    @State private var servers: ServerStore
    @State private var connections: ConnectionManager
    @State private var transfers: TransferManager
    @State private var operations: FileOperations
    @State private var watch: SeedboxWatch
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    init() {
        HUDFont.registerBundled()
        let servers = ServerStore()
        let connections = ConnectionManager()
        _servers = State(initialValue: servers)
        _connections = State(initialValue: connections)
        let transfers = TransferManager(servers: servers, verifier: connections.verifier)
        _transfers = State(initialValue: transfers)
        let operations = FileOperations(servers: servers, connections: connections, transfers: transfers)
        _operations = State(initialValue: operations)
        // Watch mode (PRD R5.10): new finished downloads, as verified copies.
        let watch = SeedboxWatch(servers: servers, connections: connections) { sources, folder in
            await operations.place(sources, into: .local(folder), destinationName: folder.lastPathComponent, mode: .copy)
        }
        SeedboxWatch.shared = watch
        TorrentLibrary.shared = TorrentLibrary(servers: servers, connections: connections)
        TorrentStatusBoard.shared.start()
        WelcomeBack.shared.transfers = transfers
        WelcomeBack.shared.start()
        _watch = State(initialValue: watch)
        VerifiedIndex.shared.load()
        // "Copy with Blit" (App Intent) enqueues through the same manager.
        AppDependencyManager.shared.add(dependency: transfers)
    }

    var body: some Scene {
        WindowGroup("Blit", id: "main") {
            ContentView()
                .environment(sidebar)
                .environment(servers)
                .environment(connections)
                .environment(transfers)
                .environment(operations)
                .environment(watch)
                .onAppear {
                    appDelegate.transfers = transfers
                    NotificationRouter.shared.transfers = transfers
                    watch.start()
                }
                .frame(minWidth: 760, minHeight: 440)
        }
        .windowToolbarStyle(.unified)
        .commands {
            BrowserCommands(transfers: transfers)
            FileCommands(operations: operations)
            GoCommands()
            AboutCommands()
            CommandGroup(after: .appSettings) {
                // As in Finder: deleted files keep their space until the Trash is emptied.
                Button("Empty Trash…") { Task { await transfers.emptyAllTrash() } }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
            }
            CommandGroup(after: .importExport) {
                Button("Import Servers from Transmit or ForkLift…") {
                    NotificationCenter.default.post(name: .blitImportServers, object: nil)
                }
                Button("Export Transfer Log…") { TransferLog.export() }
            }
            TransferLogCommands()
            TabCommands()
            CommandGroup(after: .help) {
                Button("Welcome to Blit…") { NotificationCenter.default.post(name: .blitShowWelcome, object: nil) }
            }

        }

        MenuBarExtra(isInserted: $showMenuBarExtra) {
            MenuBarPanel()
                .environment(transfers)
        } label: {
            MenuBarLabel()
                .environment(transfers)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }

        Window("Transfer Log", id: "transfer-log") {
            TransferLogView()
        }
        .defaultSize(width: 1000, height: 560)
        .commandsRemoved()   // listed by TransferLogCommands, with its shortcut

        Window("About Blit", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        // Opened from About Blit: the third-party notices Blit ships.
        Window("Acknowledgements", id: "acknowledgements") {
            AcknowledgementsView()
        }
        .defaultSize(width: 820, height: 640)
        .windowStyle(.hiddenTitleBar)
        .restorationBehavior(.disabled)
        .commandsRemoved()
    }
}

extension Notification.Name {
    /// Edit › Find (⌘F): focus the toolbar search.
    static let blitFocusSearch = Notification.Name("BlitFocusSearch")
    /// Go › Go to… (⌘K): open the jump palette.
    static let blitShowPalette = Notification.Name("BlitShowPalette")
    /// File › Import Servers…: the import sheet (PRD R1.8).
    static let blitImportServers = Notification.Name("BlitImportServers")
    /// Help › Welcome to Blit…: the first-run Welcome (PRD R2.24); the object
    /// may be the step to open at.
    static let blitShowWelcome = Notification.Name("BlitShowWelcome")
    #if DEBUG
    /// Closes the import sheet (the tests never import).
    static let blitCloseImportServers = Notification.Name("BlitCloseImportServers")
    #endif
}

extension FocusedValues {
    @Entry var browser: BrowserModel?
    @Entry var transferDetails: TransferDetailsState?
    /// True while something that takes typing is up in the window (a rename,
    /// a sheet, the toolbar search): Edit commands stay enabled to reach it.
    @Entry var textSurface: Bool?
    /// The main window's tabs (R2.18), for File › Close Tab and the Window menu.
    @Entry var paneTabs: TabsState?
}

struct TabsState: Equatable {
    var titles: [String]
    var selected: Int
}

/// Watches the general pasteboard (it posts no notification), so Edit › Paste
/// enables and disables as the clipboard changes, like the context menus.
@MainActor
@Observable
final class PasteboardWatcher {
    static let general = PasteboardWatcher()
    private(set) var changeCount = NSPasteboard.general.changeCount

    private init() {
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let watcher = PasteboardWatcher.general
                let count = NSPasteboard.general.changeCount
                if count != watcher.changeCount { watcher.changeCount = count }
            }
        }
    }
}

/// The HUD's state for the View menu (commands don't track the manager itself).
struct TransferDetailsState: Equatable {
    var isExpanded: Bool
    var available: Bool
}

/// View menu items that act on the front window's browser.
struct BrowserCommands: Commands {
    let transfers: TransferManager
    @FocusedValue(\.browser) private var browser
    @FocusedValue(\.transferDetails) private var details
    @AppStorage("showSecondPane") private var showSecondPane = true
    @AppStorage("showPathBar") private var showPathBar = true
    @AppStorage("showIconPreviews") private var showIconPreviews = true

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button("Refresh") { browser?.reload() }
                .keyboardShortcut("r")
                .disabled(browser?.current == nil)
            Divider()
            Menu("Sort By") {
                // Finder's shortcuts for the same columns.
                ForEach([(SortColumn.name, "1"), (.kind, "2"), (.modified, "5"), (.size, "6")], id: \.0) { column, key in
                    Toggle(column.title, isOn: Binding(get: { browser?.sortColumn == column },
                                                       set: { _ in browser?.sort(by: column) }))
                        .keyboardShortcut(KeyEquivalent(Character(key)), modifiers: [.command, .option, .control])
                }
            }
            .disabled(browser?.current == nil)
            Divider()
            Button(showPathBar ? "Hide Path Bar" : "Show Path Bar") { showPathBar.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Toggle("Show Icon Previews", isOn: $showIconPreviews)
            Button(browser?.showHidden == true ? "Hide Hidden Files" : "Show Hidden Files") {
                browser?.toggleHidden()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(browser == nil)
            Button(showSecondPane ? "Hide Second Pane" : "Show Second Pane") { showSecondPane.toggle() }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("Swap Panes") { BrowserModel.swapPanes?() }
                .keyboardShortcut("u")
                .disabled(!showSecondPane)
            // Marks what the other pane's folder has (PRD R2.22). Not ⌥⌘C:
            // that's Finder's Copy as Pathname. Read here, so the check follows.
            let comparing = Panes.shared.comparing
            Toggle("Compare Panes", isOn: Binding(get: { comparing }, set: { Panes.shared.comparing = $0 }))
                .keyboardShortcut("c", modifiers: [.command, .control])
                .disabled(!showSecondPane)
            // The same switches as right-clicking a column header, easier to find.
            Menu("Columns") {
                ForEach(ColumnSettings.optional, id: \.id) { column in
                    Toggle(column.title, isOn: Binding(get: { ColumnSettings.shared.isShown(column.id) },
                                                       set: { _ in ColumnSettings.shared.toggle(column.id) }))
                }
            }
            Divider()
            // The full HUD from the keyboard; Escape also collapses it.
            Button(details?.isExpanded == true ? "Hide Transfer Details" : "Show Transfer Details") {
                if transfers.isExpanded { transfers.collapse() } else { transfers.isExpanded = true }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])   // ⌥⌘T is Show/Hide Toolbar
            .disabled(details?.available != true)
            ClearQueueMenuItem(transfers: transfers)
        }
    }
}

/// File and Edit menu items for file management (PRD R2.12). Cut, Copy, Paste
/// and Select All act on files unless a text field is being edited, so they
/// keep working in the Go to… field and the server sheets; with no text
/// surface up they enable like the context menus (Paste only when the
/// clipboard holds files, Cut and Copy only with a selection).
struct FileCommands: Commands {
    let operations: FileOperations
    @FocusedValue(\.browser) private var browser
    @FocusedValue(\.textSurface) private var textSurface

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Folder") { onFiles { $0.newFolder() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(browser?.current == nil)
            // Finder's: several items in one folder into a new folder of their own.
            Button((browser?.selection.count ?? 0) > 1
                   ? "New Folder with Selection (\(browser?.selection.count ?? 0) Items)" : "New Folder with Selection") {
                onFiles { $0.newFolder(with: $0.selectedItems) }
            }
            .keyboardShortcut("n", modifiers: [.command, .control])
            .disabled(!(browser?.canMakeFolderWithSelection ?? false))
            Divider()
            Button("Quick Look") { onFiles { $0.togglePreview() } }
                .keyboardShortcut("y")
                .disabled(browser?.selection.isEmpty ?? true)
            Button("Open") { onFiles { $0.openSelection() } }
                .keyboardShortcut(.downArrow)
                .disabled(browser?.selection.count != 1)
            Button("Get Info") { onFiles { $0.infoItem = $0.selectedItems.first } }
                .keyboardShortcut("i")
                .disabled(browser?.selection.count != 1)
            Button((browser?.selection.count ?? 0) > 1 ? "Rename \(browser?.selection.count ?? 0) Items…" : "Rename") {
                onFiles { $0.beginRename($0.selectedItems) }
            }
            .disabled(browser?.selection.isEmpty ?? true)
            // To the folder the other pane shows, as in two-pane file managers.
            Button("Copy to Other Pane") { onFiles { $0.sendToOtherPane(move: false) } }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!)), modifiers: [])
                .disabled(!(browser?.canSendToOtherPane ?? false))
            Button("Move to Other Pane") { onFiles { $0.sendToOtherPane(move: true) } }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF6FunctionKey)!)), modifiers: [])
                .disabled(!(browser?.canSendToOtherPane ?? false))
            // Where items like these went last (PRD R2.23).
            let suggestion = browser?.suggestedDestinations.first
            Button(suggestion.map { "Copy to “\($0.name)”" } ?? "Copy to Suggested Folder") { onFiles { $0.sendToSuggestion(move: false) } }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF5FunctionKey)!)), modifiers: [.shift])
                .disabled(suggestion == nil)
            Button(suggestion.map { "Move to “\($0.name)”" } ?? "Move to Suggested Folder") { onFiles { $0.sendToSuggestion(move: true) } }
                .keyboardShortcut(KeyEquivalent(Character(UnicodeScalar(NSF6FunctionKey)!)), modifiers: [.shift])
                .disabled(suggestion == nil)
            // Shoot folders' edit files to the NAS (PRD R2.26): the selected shoots,
            // this shoot, or every shoot in this folder.
            Button("Back Up Photo Edits…") {
                onFiles { browser in
                    let folders = EditBackup.folders(selected: browser.selectedItems, in: browser)
                    if folders.isEmpty {
                        browser.report("No shoot folders here: Back Up Photo Edits works on folders named by date, like 2026-10-13_Boston.",
                                       action: "BACK UP EDITS")
                    } else {
                        browser.editBackupFolders = folders
                    }
                }
            }
            .disabled(browser?.current?.localURL == nil)
            Button("Open in Other Pane") { onFiles { $0.openSelectionInOtherPane() } }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!(browser.map { $0.selection.count == 1 && $0.selectedItems.first?.isDirectory == true } ?? false)
                          || browser.flatMap { BrowserModel.oppositePane?($0) } == nil)
            Divider()
            Button("Duplicate") { onFiles { $0.duplicate($0.selectedItems) } }
                .disabled(browser.map { $0.selection.isEmpty || $0.current?.localURL == nil } ?? true)
            Button(browser.map { $0.deleteTitle(for: $0.selectedItems) } ?? "Move to Trash") {
                edit(#selector(NSResponder.deleteToBeginningOfLine(_:))) { $0.requestDelete($0.selectedItems) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(browser?.selection.isEmpty ?? true)
        }
        CommandGroup(replacing: .pasteboard) {
            Button("Cut") { edit(#selector(NSText.cut(_:))) { $0.copy($0.selectedItems, cut: true) } }
                .keyboardShortcut("x")
                .disabled(!mayEditText && (browser?.selection.isEmpty ?? true))
            Button("Copy") { edit(#selector(NSText.copy(_:))) { $0.copy($0.selectedItems, cut: false) } }
                .keyboardShortcut("c")
                .disabled(!mayEditText && (browser?.selection.isEmpty ?? true))
            Button("Paste") { edit(#selector(NSText.paste(_:))) { $0.paste(move: false) } }
                .keyboardShortcut("v")
                .disabled(!mayEditText && !canPasteFiles)
            Button("Move Items Here") { onFiles { $0.paste(move: true) } }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(!canPasteFiles)
            Button("Select All") { edit(#selector(NSText.selectAll(_:))) { $0.selectAll() } }
                .keyboardShortcut("a")
        }
    }

    /// A text field may have the keyboard (nil: no browser window is key, and
    /// the commands just route down the responder chain).
    private var mayEditText: Bool { textSurface ?? true }

    /// Paste as a file command: the clipboard holds files and a folder is shown,
    /// matching the context menus. Reading the watcher re-checks it as the
    /// clipboard changes, which the menu can't see on its own.
    @MainActor private var canPasteFiles: Bool {
        _ = PasteboardWatcher.general.changeCount
        return operations.canPaste && browser?.current != nil
    }

    /// True while a text field or a sheet has the keyboard: file commands then
    /// stay out of the way (⌘⌫ in a name field must not trash the selection).
    @MainActor private var isEditingText: Bool {
        guard let window = NSApp.keyWindow else { return true }
        return window.firstResponder is NSText || window.sheetParent != nil || window.attachedSheet != nil
    }

    @MainActor private func onFiles(_ action: (BrowserModel) -> Void) {
        guard !isEditingText, let browser else { return }
        action(browser)
    }

    /// Sends a text action to the field being edited, or acts on the files.
    @MainActor private func edit(_ textAction: Selector, files: (BrowserModel) -> Void) {
        if isEditingText {
            NSApp.sendAction(textAction, to: nil, from: nil)
        } else if let browser {
            files(browser)
        }
    }
}

/// Blit › About Blit opens the pixel-terminal About window.
struct AboutCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Blit") { openWindow(id: "about") }
            Button("Check for Updates…") { Updates.shared.checkNow() }
                .disabled(!Updates.shared.isAvailable)
            if LicenseManager.shared.isEnforced {
                Divider()
                LicenseMenuItems()
            }
        }
    }
}

/// Blit › Buy Blit… and Enter License…, or License… once a key is in (nothing to buy or enter
/// then; Settings › License shows whose it is and Deactivate This Mac). A view of its own: SwiftUI
/// follows what a view's body reads, and in the commands' body a change of license left the menu
/// as it was (as Rune found, 2026-10-11).
struct LicenseMenuItems: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if LicenseManager.shared.isLicensed {
            Button("License…") { openLicense() }
        } else {
            Button("Buy Blit…") { LicenseManager.shared.openBuyPage() }
            // Straight to the key field (the receipt and the checkout say so).
            Button("Enter License…") { openLicense() }
        }
    }

    private func openLicense() {
        SettingsView.tabStore.set("license", forKey: SettingsView.tabKey)
        openSettings()
    }
}

/// Go › Go to Folder (⇧⌘G), as in Finder.
struct GoCommands: Commands {
    @FocusedValue(\.browser) private var browser

    var body: some Commands {
        CommandMenu("Go") {
            // Jump to a favorite, server, drive or recent folder (the ⌘K palette).
            Button("Go to…") { NotificationCenter.default.post(name: .blitShowPalette, object: nil) }
                .keyboardShortcut("k", modifiers: .command)
            Button("Go to Folder…") { browser?.showGoToFolder = true }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(browser == nil)
        }
        CommandGroup(after: .textEditing) {
            Button("Find") { NotificationCenter.default.post(name: .blitFocusSearch, object: nil) }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(browser?.current == nil)
        }
    }
}

/// Tabs of pairs (R2.18): File › New Tab and Close Tab, and in the Window
/// menu the next and previous tab and each tab by its ⌘-number, as in Safari.
struct TabCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.paneTabs) private var state

    var body: some Commands {
        let count = state?.titles.count ?? 0
        CommandGroup(before: .newItem) {
            Button("New Tab") {
                // With the window closed, ⌘T brings it back (its tabs kept).
                if state != nil { PaneTabs.shared.newTab() } else { openWindow(id: "main") }
            }
            .keyboardShortcut("t")
            // Listed before File › Close, so ⌘W closes a tab while there are
            // several; with one left it's disabled, and ⌘W closes the window.
            Button("Close Tab") { if let id = PaneTabs.shared.current?.id { PaneTabs.shared.close(id) } }
                .keyboardShortcut("w")
                .disabled(count < 2)
            Divider()
        }
        CommandGroup(before: .windowList) {
            Button("Show Previous Tab") { PaneTabs.shared.selectNext(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
                .disabled(count < 2)
            Button("Show Next Tab") { PaneTabs.shared.selectNext(1) }
                .keyboardShortcut(.tab, modifiers: .control)
                .disabled(count < 2)
            if let state, count > 1 {
                Divider()
                ForEach(Array(state.titles.prefix(9).enumerated()), id: \.offset) { index, title in
                    Toggle(title, isOn: Binding(get: { state.selected == index },
                                                set: { _ in PaneTabs.shared.select(index: index) }))
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                }
            }
            Divider()
        }
    }
}

/// Window › Transfer Log (⌥⌘L).
struct TransferLogCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(before: .windowArrangement) {
            Button("Transfer Log") { openWindow(id: "transfer-log") }
                .keyboardShortcut("l", modifiers: [.command, .option])
        }
    }
}
