// Blit — a native macOS utility that moves big files fast and verifies every byte.

import SwiftUI

@main
struct BlitApp: App {
    @State private var sidebar = SidebarModel()
    @State private var servers: ServerStore
    @State private var connections: ConnectionManager
    @State private var transfers: TransferManager

    init() {
        HUDFont.registerBundled()
        let servers = ServerStore()
        let connections = ConnectionManager()
        _servers = State(initialValue: servers)
        _connections = State(initialValue: connections)
        _transfers = State(initialValue: TransferManager(servers: servers, verifier: connections.verifier))
    }

    var body: some Scene {
        WindowGroup("Blit") {
            ContentView()
                .environment(sidebar)
                .environment(servers)
                .environment(connections)
                .environment(transfers)
                .frame(minWidth: 760, minHeight: 440)
        }
        .windowToolbarStyle(.unified)
        .commands { BrowserCommands() }
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
