import SwiftUI

struct ContentView: View {
    @Environment(SidebarModel.self) private var sidebar
    @State private var browser = BrowserModel()
    @State private var selection: URL?

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 280)
        } detail: {
            FileListView(browser: browser)
        }
        .navigationTitle(browser.current?.lastPathComponent ?? "Blit")
        .navigationSubtitle(browser.current.map { ($0.path as NSString).abbreviatingWithTildeInPath } ?? "")
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button("Back", systemImage: "chevron.left") { browser.goBack() }
                    .disabled(!browser.canGoBack)
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward", systemImage: "chevron.right") { browser.goForward() }
                    .disabled(!browser.canGoForward)
                    .keyboardShortcut("]", modifiers: .command)
            }
            ToolbarItemGroup {
                Button("Enclosing Folder", systemImage: "arrow.up") { browser.goUp() }
                    .disabled(!browser.canGoUp)
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Add to Favorites", systemImage: "star") {
                    if let url = browser.current { sidebar.addFavorites([url]) }
                }
                .disabled(browser.current.map(sidebar.isFavorite) ?? true)
                .keyboardShortcut("d", modifiers: .command)
                .help("Add this folder to Favorites (⌘D)")
            }
        }
        .onChange(of: selection) { _, url in
            if let url { browser.open(url) }
        }
        .onAppear {
            if selection == nil {
                selection = sidebar.favorites.first(where: sidebar.isAvailable)?.url
                    ?? sidebar.drives.first(where: { !$0.isInternal })?.url
                    ?? FileManager.default.homeDirectoryForCurrentUser
            }
        }
    }
}
