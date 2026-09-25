// Blit — a native macOS utility that moves big files fast and verifies every byte.

import AppIntents
import AppKit
import SwiftUI

/// Quitting mid-transfer: save the queue, close connections, then exit. A
/// short watchdog guarantees the process ends even if something still holds
/// it open; resume data (queue.json, .blitpart state) is already on disk.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var transfers: TransferManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
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
            BrowserCommands()
            FileCommands()
            CommandGroup(after: .importExport) {
                Button("Export Transfer Log…") { TransferLog.export() }
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
    }
}

extension FocusedValues {
    @Entry var browser: BrowserModel?
}

/// View menu items that act on the front window's browser.
struct BrowserCommands: Commands {
    @FocusedValue(\.browser) private var browser
    @AppStorage("showSecondPane") private var showSecondPane = false

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(browser?.showHidden == true ? "Hide Hidden Files" : "Show Hidden Files") {
                browser?.toggleHidden()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(browser == nil)
            Button(showSecondPane ? "Hide Second Pane" : "Show Second Pane") { showSecondPane.toggle() }
                .keyboardShortcut("2", modifiers: [.command, .option])
        }
    }
}

/// File and Edit menu items for file management (PRD R2.12). Cut, Copy, Paste
/// and Select All act on files unless a text field is being edited, so they
/// keep working in the Go to… field and the server sheets.
struct FileCommands: Commands {
    @FocusedValue(\.browser) private var browser

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Folder") { onFiles { $0.promptNewFolder() } }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(browser?.current == nil)
            Divider()
            Button("Rename…") { onFiles { b in b.selectedItems.first.map(b.promptRename) } }
                .disabled(browser?.selection.count != 1)
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
