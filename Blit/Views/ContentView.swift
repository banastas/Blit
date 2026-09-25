import BlitRemote
import SwiftUI

struct ContentView: View {
    @Environment(SidebarModel.self) private var sidebar
    @Environment(ServerStore.self) private var servers
    @Environment(ConnectionManager.self) private var connections
    @Environment(TransferManager.self) private var transfers
    @Environment(FileOperations.self) private var operations
    @State private var browser: BrowserModel?
    /// The optional second pane (R2.8) and which pane sidebar picks, ⌘K and
    /// the toolbar act on (the one last clicked).
    @State private var secondBrowser: BrowserModel?
    @State private var secondActive = false
    @AppStorage("showSecondPane") private var showSecondPane = false
    @State private var transferError: String?
    @State private var nasShare: VolumeLocation?
    @State private var showPalette = false
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
                        onTransfer: drop,
                        onNASVerification: { nasShare = $0 },
                        onRefresh: refresh)
                .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 300)
        } detail: {
            if let browser {
                Group {
                    if showSecondPane, let secondBrowser {
                        HSplitView {
                            pane(browser, isActive: !secondActive) { secondActive = false }
                            pane(secondBrowser, isActive: secondActive) { secondActive = true }
                        }
                    } else {
                        FileListView(browser: browser)
                    }
                }
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        if let job = transfers.featured {
                            Group {
                                // File operations only ever use the condensed strip.
                                if transfers.isExpanded, !job.isOperation {
                                    TransferHUD(job: job).transition(.crt)
                                } else {
                                    TransferStrip(job: job).transition(.crt)
                                }
                            }
                            .padding(8)
                            .transition(.crt)
                        }
                    }
                    .animation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.36), value: transfers.isExpanded)
                    .animation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.36), value: transfers.featured == nil)
            }
        }
        .navigationTitle(active?.title ?? "Blit")
        .navigationSubtitle(active?.subtitle ?? "")
        .toolbar { toolbar }
        .onChange(of: selection) { _, location in
            if let location { active?.open(location) }
        }
        .onChange(of: showSecondPane) { _, shown in
            if shown { openSecondPaneIfNeeded() } else { secondActive = false }
        }
        .onAppear(perform: start)
        .background(WindowReader { BrowserModel.activeWindow = $0 })
        .onChange(of: secondActive) { BrowserModel.active = active }
        .onChange(of: showSecondPane) { BrowserModel.active = active }
        .focusedSceneValue(\.browser, active)
        .sheet(item: $editing) { item in
            ServerEditor(server: item.server, isNew: item.isNew) { server, password in
                servers.save(server, password: password)
                connections.disconnect(server)
                if item.isNew { selection = server.startLocation } else if active?.current?.serverID == server.id { active?.reload() }
            }
        }
        .sheet(isPresented: externalFilesBinding) {
            let files = transfers.pendingExternalFiles
            CommandPalette(entries: paletteEntries.filter { $0.location.localURL != nil && $0.group != .recent },
                           prompt: files.count == 1 ? "Send “\(files[0].lastPathComponent)” to…" : "Send \(files.count) items to…") { location in
                let name = location.localURL?.lastPathComponent ?? "Folder"
                startTransfer(files.map { .local($0) }, to: location, name: name)
            }
            .onDisappear { transfers.pendingExternalFiles = [] }
        }
        .sheet(isPresented: $showPalette) {
            CommandPalette(entries: paletteEntries) { location in
                selection = location
                active?.open(location)
            }
        }
        .sheet(item: $nasShare) { share in
            NASVerificationSheet(share: share, existing: servers.nasLogin(forMount: share.url.path),
                                 verifier: connections.verifier) { login, password in
                servers.save(login, password: password)
            }
        }
        .sheet(item: trustBinding) { request in
            TrustSheet(request: request) {
                try? HostKeyStore().pin(request.presented, host: request.server.host, port: request.server.port)
                active?.reload()
            }
        }
        .sheet(item: passwordBinding) { server in
            PasswordSheet(server: server) { password in
                Keychain.setPassword(password, for: server)
                connections.disconnect(server)
                active?.reload()
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

    /// Sidebar › Refresh: reloads every pane showing `location` or something
    /// inside it (for a server, anything on it); if none does, opens it.
    /// Reconnect reopens the server's browsing session first.
    private func refresh(_ location: BrowseLocation, reconnect: Bool) {
        let server = servers.server(location.serverID)
        if reconnect, let server { connections.disconnect(server) }
        let panes = [browser, showSecondPane ? secondBrowser : nil].compactMap { $0 }
        let showing = panes.filter { model in
            guard let current = model.current else { return false }
            if let server { return current.serverID == server.id }
            return FileOperations.location(location, contains: current)
        }
        if showing.isEmpty {
            selection = location
            active?.open(location)
        } else {
            showing.forEach { $0.reload() }
        }
    }

    /// A drop onto the sidebar: Finder's rules (move within a volume or server,
    /// copy across), ⌥ copies.
    private func drop(_ sources: [BrowseLocation], to destination: BrowseLocation, name: String) {
        let mode: FileOperations.Mode = NSEvent.modifierFlags.contains(.option) ? .copy : .automatic
        let hidden = active?.showHidden ?? false
        Task {
            transferError = await operations.place(sources, into: destination, destinationName: name.isEmpty ? "Folder" : name,
                                                   mode: mode, includeHidden: hidden)
        }
    }

    private func startTransfer(_ sources: [BrowseLocation], to destination: BrowseLocation, name: String) {
        transferError = transfers.enqueue(sources, to: destination, destinationName: name.isEmpty ? "Folder" : name,
                                          includeHidden: active?.showHidden ?? false)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.left") { active?.goBack() }
                .disabled(!(active?.canGoBack ?? false))
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward", systemImage: "chevron.right") { active?.goForward() }
                .disabled(!(active?.canGoForward ?? false))
                .keyboardShortcut("]", modifiers: .command)
        }
        ToolbarItemGroup {
            Button("Go to…", systemImage: "magnifyingglass") { showPalette = true }
                .keyboardShortcut("k", modifiers: .command)
                .help("Go to a favorite, server, drive or recent folder (⌘K)")
            Button("New Folder", systemImage: "folder.badge.plus") { active?.promptNewFolder() }
                .disabled(active?.current == nil)
                .help("New Folder (⇧⌘N)")
            Button("Enclosing Folder", systemImage: "arrow.up") { active?.goUp() }
                .disabled(!(active?.canGoUp ?? false))
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("Add to Favorites", systemImage: "star") {
                if let location = active?.current { sidebar.addFavorite(location) }
            }
            .disabled(active?.current.map(sidebar.isFavorite) ?? true)
            .keyboardShortcut("d", modifiers: .command)
            .help("Add this folder to Favorites (⌘D)")
        }
    }

    /// Everything ⌘K can jump to, deduplicated by location.
    private var paletteEntries: [PaletteEntry] {
        var seen = Set<BrowseLocation>()
        var entries: [PaletteEntry] = []
        func add(_ location: BrowseLocation, _ name: String, _ detail: String, _ symbol: String, _ group: PaletteEntry.Group) {
            guard seen.insert(location).inserted else { return }
            entries.append(PaletteEntry(location: location, name: name, detail: detail, symbol: symbol, group: group))
        }
        func describe(_ location: BrowseLocation) -> (name: String, detail: String) {
            switch location {
            case .local(let url):
                return (url.path == "/" ? "Macintosh HD" : url.lastPathComponent, (url.path as NSString).abbreviatingWithTildeInPath)
            case .remote(let id, let bytes):
                let server = servers.server(id)?.displayName ?? "Server"
                let path = bytes.isEmpty ? "~" : String(decoding: bytes, as: UTF8.self)
                return (location.lastComponent.isEmpty ? server : location.lastComponent, "\(server):\(path)")
            }
        }
        for favorite in sidebar.favorites {
            let d = describe(favorite.location)
            add(favorite.location, d.name, d.detail, "star", .favorite)
        }
        for server in servers.browsable {
            add(server.startLocation, server.displayName, "\(server.username)@\(server.host)", "server.rack", .server)
        }
        for drive in sidebar.drives {
            add(.local(drive.url), drive.name, drive.url.path, drive.isInternal ? "internaldrive" : "externaldrive", .drive)
        }
        for share in sidebar.networkShares {
            add(.local(share.url), share.name, "\(share.host ?? "Network") · \(share.url.path)", "externaldrive.connected.to.line.below", .nas)
        }
        for recent in active?.recents ?? [] {
            let d = describe(recent)
            add(recent, d.name, d.detail, "clock", .recent)
        }
        return entries
    }

    private var externalFilesBinding: Binding<Bool> {
        Binding(get: { !transfers.pendingExternalFiles.isEmpty }, set: { if !$0 { transfers.pendingExternalFiles = [] } })
    }

    private var trustBinding: Binding<TrustRequest?> {
        Binding(get: { active?.trustRequest }, set: { active?.trustRequest = $0 })
    }

    private var passwordBinding: Binding<ServerConfig?> {
        Binding(get: { active?.passwordRequest }, set: { active?.passwordRequest = $0 })
    }

    /// The browser that sidebar picks, ⌘K and the toolbar act on.
    private var active: BrowserModel? { showSecondPane && secondActive ? secondBrowser : browser }

    /// One pane of the two-pane layout, with a small location header.
    private func pane(_ model: BrowserModel, isActive: Bool, activate: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: model.current?.serverID != nil ? "server.rack" : "folder")
                    .foregroundStyle(.secondary)
                Text(model.title).fontWeight(isActive ? .semibold : .regular)
                Text(model.subtitle).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(isActive ? Color.accentColor.opacity(0.12) : Color.clear)
            .contentShape(Rectangle())
            .onTapGesture(perform: activate)
            Divider()
            FileListView(browser: model)
                .simultaneousGesture(TapGesture().onEnded(activate))
        }
        .frame(minWidth: 280)
    }

    private func openSecondPaneIfNeeded() {
        if secondBrowser == nil {
            secondBrowser = BrowserModel(servers: servers, connections: connections, operations: operations)
        }
        guard let secondBrowser, secondBrowser.current == nil else { return }
        let start = sidebar.favorites.dropFirst().first(where: sidebar.isAvailable)?.location
            ?? sidebar.networkShares.first.map { .local($0.url) }
            ?? .local(FileManager.default.homeDirectoryForCurrentUser)
        secondBrowser.open(start)
    }

    private func start() {
        if browser == nil { browser = BrowserModel(servers: servers, connections: connections, operations: operations) }
        if showSecondPane { openSecondPaneIfNeeded() }
        BrowserModel.active = active
        transfers.restoreQueue()
        connections.warmUp(servers.browsable)
        // Refresh whichever panes show a folder that changed: a transfer's
        // destination (and a move's sources), or a file operation's folders.
        let refresh: ([BrowseLocation]) -> Void = { [weak browser, weak secondBrowser] folders in
            for model in [browser, secondBrowser].compactMap({ $0 }) {
                if folders.contains(where: model.shows) { model.reload() }
            }
        }
        operations.onChanged = refresh
        transfers.onFinished = { job in
            refresh([.local(job.destination)] + (job.deleteSources ? job.sources.compactMap(\.parent) : []))
        }
        if selection == nil {
            selection = sidebar.favorites.first(where: sidebar.isAvailable)?.location
                ?? sidebar.drives.first(where: { !$0.isInternal }).map { .local($0.url) }
                ?? .local(FileManager.default.homeDirectoryForCurrentUser)
        }
    }
}

/// Hands over the window hosting a view (for key handling that needs it).
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(view.window) }
    }
}
