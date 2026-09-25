// Blit — a native macOS utility that moves big files fast and verifies every byte.

import SwiftUI

@main
struct BlitApp: App {
    @State private var sidebar = SidebarModel()

    var body: some Scene {
        WindowGroup("Blit") {
            ContentView()
                .environment(sidebar)
                .frame(minWidth: 760, minHeight: 440)
        }
        .windowToolbarStyle(.unified)
    }
}
