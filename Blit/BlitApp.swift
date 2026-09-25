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
    @AppStorage("showMenuBarExtra") private var showMenuBarExtra = true

    init() {
        HUDFont.registerBundled()
        let servers = ServerStore()
        let connections = ConnectionManager()
        _servers = State(initialValue: servers)
        _connections = State(initialValue: connections)
        let transfers = TransferManager(servers: servers, verifier: connections.verifier)
        _transfers = State(initialValue: transfers)
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
                .onAppear { appDelegate.transfers = transfers }
                .frame(minWidth: 760, minHeight: 440)
        }
        .windowToolbarStyle(.unified)
        .commands { BrowserCommands() }

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

    var body: some Commands {
        CommandGroup(after: .sidebar) {
            Button(browser?.showHidden == true ? "Hide Hidden Files" : "Show Hidden Files") {
                browser?.toggleHidden()
            }
            .keyboardShortcut(".", modifiers: [.command, .shift])
            .disabled(browser == nil)
        }
    }
}
