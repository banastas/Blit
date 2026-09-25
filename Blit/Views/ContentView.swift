import BlitRemote
import SwiftUI

struct ContentView: View {
    @Environment(SidebarModel.self) private var sidebar
    @Environment(ServerStore.self) private var servers
    @Environment(ConnectionManager.self) private var connections
    @Environment(TransferManager.self) private var transfers
    @State private var browser: BrowserModel?
    @State private var transferError: String?
    @State private var selection: BrowseLocation?
    @State private var editing: EditingServer?
    @State private var removing: ServerConfig?

    struct EditingServer: Identifiable {
        var server: ServerConfig
        var isNew: Bool
        var id: UUID { server.id }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(selection: $selection,
                        onAddServer: { editing = EditingServer(server: ServerConfig(), isNew: true) },
                        onEditServer: { editing = EditingServer(server: $0, isNew: false) },
                        onRemoveServer: { removing = $0 },
                        onTransfer: startTransfer)
                .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 300)
        } detail: {
            if let browser {
                FileListView(browser: browser, onTransfer: startTransfer)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if let job = transfers.featured {
                            TransferStrip(job: job)
                                .padding(8)
                        }
                    }
            }
        }
        .navigationTitle(browser?.title ?? "Blit")
        .navigationSubtitle(browser?.subtitle ?? "")
        .toolbar { toolbar }
        .onChange(of: selection) { _, location in
            if let location { browser?.open(location) }
        }
        .onAppear(perform: start)
        .sheet(item: $editing) { item in
            ServerEditor(server: item.server, isNew: item.isNew) { server, password in
                servers.save(server, password: password)
                connections.disconnect(server)
                if item.isNew { selection = server.startLocation } else if selection?.serverID == server.id { browser?.reload() }
            }
        }
        .sheet(item: trustBinding) { request in
            TrustSheet(request: request) {
                try? HostKeyStore().pin(request.presented, host: request.server.host, port: request.server.port)
                browser?.reload()
            }
        }
        .sheet(item: passwordBinding) { server in
            PasswordSheet(server: server) { password in
                Keychain.setPassword(password, for: server)
                connections.disconnect(server)
                browser?.reload()
            }
        }
        .confirmationDialog("Remove “\(removing?.displayName ?? "")”?", isPresented: .constant(removing != nil), presenting: removing) { server in
            Button("Remove", role: .destructive) {
                connections.disconnect(server)
                sidebar.removeFavorites(onServer: server.id)
                servers.remove(server)
                if selection?.serverID == server.id { selection = nil }
                removing = nil
            }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { _ in
            Text("Its saved password is removed from your Keychain, along with any favorites on it.")
        }
        .alert("Can't Transfer", isPresented: Binding(get: { transferError != nil }, set: { if !$0 { transferError = nil } })) {
            Button("OK") { transferError = nil }
        } message: {
            Text(transferError ?? "")
        }
    }

    private func startTransfer(_ sources: [BrowseLocation], to destination: BrowseLocation, name: String) {
        transferError = transfers.enqueue(sources, to: destination, destinationName: name.isEmpty ? "Folder" : name)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.left") { browser?.goBack() }
                .disabled(!(browser?.canGoBack ?? false))
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward", systemImage: "chevron.right") { browser?.goForward() }
                .disabled(!(browser?.canGoForward ?? false))
                .keyboardShortcut("]", modifiers: .command)
        }
        ToolbarItemGroup {
            Button("Enclosing Folder", systemImage: "arrow.up") { browser?.goUp() }
                .disabled(!(browser?.canGoUp ?? false))
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Add to Favorites", systemImage: "star") {
                if let location = browser?.current { sidebar.addFavorite(location) }
            }
            .disabled(browser?.current.map(sidebar.isFavorite) ?? true)
            .keyboardShortcut("d", modifiers: .command)
            .help("Add this folder to Favorites (⌘D)")
        }
    }

    private var trustBinding: Binding<TrustRequest?> {
        Binding(get: { browser?.trustRequest }, set: { browser?.trustRequest = $0 })
    }

    private var passwordBinding: Binding<ServerConfig?> {
        Binding(get: { browser?.passwordRequest }, set: { browser?.passwordRequest = $0 })
    }

    private func start() {
        if browser == nil { browser = BrowserModel(servers: servers, connections: connections) }
        transfers.onFinished = { [weak browser] destination in
            if let browser, browser.current?.localURL?.standardizedFileURL == destination.standardizedFileURL {
                browser.reload()
            }
        }
        if selection == nil {
            selection = sidebar.favorites.first(where: sidebar.isAvailable)?.location
                ?? sidebar.drives.first(where: { !$0.isInternal }).map { .local($0.url) }
                ?? .local(FileManager.default.homeDirectoryForCurrentUser)
        }
    }
}
