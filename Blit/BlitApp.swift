// Blit — a native macOS utility that moves big files fast and verifies every byte.

import AppIntents
import AppKit
import Quartz
import SwiftUI

/// Quitting mid-transfer: save the queue, close connections, then exit. A
/// short watchdog guarantees the process ends even if something still holds
/// it open; resume data (queue.json, .blitpart state) is already on disk.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var transfers: TransferManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // One browser window: keyboard routing (Space, Return, file commands)
        // follows the window's active pane, so no second window or tabs.
        NSWindow.allowsAutomaticWindowTabbing = false
        BrowserModel.cleanUpPreviewDownloads()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        #if DEBUG
        UITestHarness.runIfRequested()
        UITestHarness.renderStatusIconsIfRequested()
        UITestHarness.runUndoTestIfRequested()
        UITestHarness.runPartialTestIfRequested()
        UITestHarness.runSortTestIfRequested()
        UITestHarness.renderPathBarIfRequested()
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
                guard let window = NSApp.keyWindow, let browser = BrowserModel.active, browser.current != nil else { return false }
                let panelIsKey = window is QLPreviewPanel
                guard panelIsKey || (window === BrowserModel.activeWindow && window.attachedSheet == nil
                                     && !(window.firstResponder is NSText)) else { return false }
                // Mid-rename (including the moment before the field takes the keyboard),
                // Space and Return belong to the name being edited.
                guard browser.renaming == nil else { return false }
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
        MainActor.assumeIsolated { BrowserModel.cleanUpPreviewDownloads() }
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
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    init() {
        HUDFont.registerBundled()
        let servers = ServerStore()
        let connections = ConnectionManager()
        _servers = State(initialValue: servers)
        _connections = State(initialValue: connections)
        let transfers = TransferManager(servers: servers, verifier: connections.verifier)
        _transfers = State(initialValue: transfers)
        _operations = State(initialValue: FileOperations(servers: servers, connections: connections, transfers: transfers))
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
                .onAppear { appDelegate.transfers = transfers }
                .frame(minWidth: 760, minHeight: 440)
        }
        .windowToolbarStyle(.unified)
        .commands {
            BrowserCommands(transfers: transfers)
            FileCommands()
            GoCommands()
            AboutCommands()
            CommandGroup(after: .importExport) {
                Button("Export Transfer Log…") { TransferLog.export() }
            }
            TransferLogCommands()

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
    }
}

extension FocusedValues {
    @Entry var browser: BrowserModel?
    @Entry var transferDetails: TransferDetailsState?
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
    @AppStorage("showSecondPane") private var showSecondPane = false
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
            Divider()
            // The full HUD from the keyboard; Escape also collapses it.
            Button(details?.isExpanded == true ? "Hide Transfer Details" : "Show Transfer Details") {
                if transfers.isExpanded { transfers.collapse() } else { transfers.isExpanded = true }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])   // ⌥⌘T is Show/Hide Toolbar
            .disabled(details?.available != true)
        }
    }
}

/// File and Edit menu items for file management (PRD R2.12). Cut, Copy, Paste
/// and Select All act on files unless a text field is being edited, so they
/// keep working in the Go to… field and the server sheets.
struct FileCommands: Commands {
    @FocusedValue(\.browser) private var browser

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Folder") { onFiles { $0.newFolder() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(browser?.current == nil)
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
            Button("Copy") { edit(#selector(NSText.copy(_:))) { $0.copy($0.selectedItems, cut: false) } }
                .keyboardShortcut("c")
            Button("Paste") { edit(#selector(NSText.paste(_:))) { $0.paste(move: false) } }
                .keyboardShortcut("v")
            Button("Move Items Here") { onFiles { $0.paste(move: true) } }
                .keyboardShortcut("v", modifiers: [.command, .option])
                .disabled(browser?.current == nil)
            Button("Select All") { edit(#selector(NSText.selectAll(_:))) { $0.selectAll() } }
                .keyboardShortcut("a")
        }
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

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Blit") { openWindow(id: "about") }
        }
    }
}

/// Go › Go to Folder (⇧⌘G), as in Finder.
struct GoCommands: Commands {
    @FocusedValue(\.browser) private var browser

    var body: some Commands {
        CommandMenu("Go") {
            Button("Go to Folder…") { browser?.showGoToFolder = true }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(browser == nil)
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
