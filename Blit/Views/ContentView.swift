import BlitRemote
import SwiftUI

struct ContentView: View {
    @Environment(SidebarModel.self) private var sidebar
    @Environment(ServerStore.self) private var servers
    @Environment(ConnectionManager.self) private var connections
    @Environment(TransferManager.self) private var transfers
    @Environment(\.openWindow) private var openWindow
    @Environment(FileOperations.self) private var operations
    @Environment(\.undoManager) private var undoManager
    @AppStorage("showSecondPane") private var showSecondPane = true
    @State private var nasShare: VolumeLocation?
    @State private var showPalette = false
    @FocusState private var searchFocused: Bool
    @State private var selection: BrowseLocation?
    @State private var editing: EditingServer?
    @State private var importingServers = false
    @State private var showingWelcome = false
    /// The first launch's Full Disk Access sheet (PRD R2.20).
    @State private var offeringFullDiskAccess = false
    @State private var removing: ServerConfig?
    /// Height of the floating transfer HUD or strip, reserved below the list.
    @State private var hudHeight: CGFloat = 0
    /// Height of the panes' area (the full HUD opens only if the lists keep
    /// about six rows above it).
    @State private var detailHeight: CGFloat = 1_000

    /// The shown tab (R2.18) and its panes: the first, the optional second
    /// (R2.8), and which one sidebar picks, ⌘K and the toolbar act on (the one
    /// last clicked).
    private var tab: PaneTab? { PaneTabs.shared.current }
    private var browser: BrowserModel? { tab?.first }
    private var secondBrowser: BrowserModel? { tab?.second }
    private var secondActive: Bool {
        get { tab?.secondActive ?? false }
        nonmutating set { tab?.secondActive = newValue }
    }

    struct EditingServer: Identifiable {
        var server: ServerConfig
        var isNew: Bool
        var id: UUID { server.id }
    }

    var body: some View {
        #if DEBUG
        let _ = UITestHarness.tick("ContentView")
        #endif
        NavigationSplitView {
            SidebarView(selection: $selection,
                        onAddServer: { editing = EditingServer(server: ServerConfig(), isNew: true) },
                        onImportServers: { importingServers = true },
                        onEditServer: { editing = EditingServer(server: $0, isNew: false) },
                        onRemoveServer: { removing = $0 },
                        onTransfer: drop,
                        onNASVerification: { nasShare = $0 },
                        onRefresh: refresh)
                .navigationSplitViewColumnWidth(min: 170, ideal: 210, max: 300)
        } detail: {
            if let tab, let browser {
                VStack(spacing: 0) {
                    if PaneTabs.shared.tabs.count > 1 { PaneTabBar(twoPanes: showSecondPane) }
                    // The same lists show every tab, each tab's own folders, rows,
                    // selection and scroll (its models), and the divider stays where
                    // it was put. A switch swaps each list's rows in place: about
                    // 50 ms, from 300 files to 10,000 (the tab switch test).
                    panes(browser)
                }
                    // Room at the bottom for the transfer HUD, which floats over it.
                    .safeAreaPadding(.bottom, transfers.featured == nil ? 0 : hudHeight)
                    // The whole height, measured outside the room kept for the HUD:
                    // measured inside, showing the HUD took the room it asks for,
                    // the strip came back, and the two went back and forth.
                    .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { _, height in
                        detailHeight = height - (PaneTabs.shared.tabs.count > 1 ? PaneTabBar.height : 0)
                    }
                    .overlay(alignment: .bottom) {
                        // An overlay, not a safe-area inset: overlays don't take part in
                        // sizing the window. As an inset, every HUD update (the percent
                        // ticking during a download) re-sized the window's content,
                        // macOS briefly reported a shorter toolbar, and the list and
                        // HUD jumped.
                        if let job = transfers.featured {
                            Group {
                                // File operations only ever use the condensed strip, and the
                                // full HUD waits for room (each pane keeps about six rows).
                                if transfers.isExpanded, !job.isOperation, hasRoomForFullHUD {
                                    TransferHUD(job: job).transition(.crt)
                                } else {
                                    TransferStrip(job: job).transition(.crt)
                                }
                            }
                            .overlay { FinishFlourish(moment: transfers.finishMoment) }
                            .padding(8)
                            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { _, height in
                                withAnimation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.36)) { hudHeight = height }
                            }
                            .transition(.crt)
                        }
                    }
                    .animation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.36), value: showsExpandedHUD)
                    .onChange(of: transfers.featured == nil) { _, none in if none { hudHeight = 0 } }
                    .animation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 0.36), value: transfers.featured == nil)
            }
        }
        // The smallest useful window: two panes (the sidebar collapses on its
        // own) with about eight rows each; also half of a 13" MacBook Air, so
        // Blit fits beside another app in Split View.
        .frame(minWidth: 720, minHeight: 480)
        // With two panes each names its own folder, so the window just says Blit.
        .navigationTitle(showSecondPane ? "Blit" : (active?.title ?? "Blit"))
        .navigationSubtitle(showSecondPane ? "" : (active?.subtitle ?? ""))
        .toolbar { toolbar }
        // Search the folder in the active pane (⌘F), as in Finder's toolbar.
        .searchable(text: searchBinding, placement: .toolbar, prompt: searchPrompt)
        .searchFocused($searchFocused)
        .onReceive(NotificationCenter.default.publisher(for: .blitFocusSearch)) { _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .blitShowPalette)) { _ in showPalette = true }
        .modifier(ImportServersHost(importing: $importingServers, selection: $selection))
        .modifier(WelcomeHost(showing: $showingWelcome))
        .modifier(WelcomeBackHost())
        .onChange(of: selection) { _, location in
            // A tick later: the sidebar's list can still be mid-update when its
            // selection changes, and reloading a pane's table from inside that
            // update re-enters the table's delegate.
            guard let location else { return }
            let pane = active
            Task { pane?.open(location) }
        }
        .onChange(of: showSecondPane) { _, shown in
            if shown {
                openSecondPaneIfNeeded()
            } else {
                // The keyboard comes back to the first pane (the second's list
                // going handed it to the toolbar's search field).
                if secondActive { browser?.requestKeyboardFocus() }
                secondActive = false
            }
            Panes.shared.twoPanes = shown
        }
        .modifier(PaneTracking(tabID: tab?.id, first: browser?.current, second: secondBrowser?.current,
                               secondActive: secondActive, follow: followActivePane, shown: tabShown))
        .onAppear(perform: start)
        .background(alignment: .topLeading) {
            WindowReader { window in
                BrowserModel.activeWindow = window
                // A debug test copy never saves its windows: it shares the
                // installed Blit's saved window state (a test that closed its
                // window left every later copy, and could leave Blit, with none).
                if TransferManager.isIsolated { window?.isRestorable = false }
            }
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
        .modifier(PaneCoordination(tabID: tab?.id, browser: browser, secondBrowser: secondBrowser, active: active,
                                   secondActive: secondActive, showSecondPane: showSecondPane,
                                   undoManager: undoManager, operations: operations))
        // Plain values, so View › Show/Hide Transfer Details updates with the HUD.
        .focusedSceneValue(\.transferDetails, TransferDetailsState(isExpanded: transfers.isExpanded,
                                                                  available: transfers.featured != nil))
        .focusedSceneValue(\.textSurface, textSurfaceUp)
        .focusedSceneValue(\.paneTabs, tabsState)
        .sheet(isPresented: $offeringFullDiskAccess) { FullDiskAccessSheet() }
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
        DestinationMemory.shared.learn(sources, into: destination)
        let mode: FileOperations.Mode = NSEvent.modifierFlags.contains(.option) ? .copy : .automatic
        let hidden = active?.showHidden ?? false
        let tab = PaneTabs.shared.current?.id
        Task {
            if let message = await operations.place(sources, into: destination, destinationName: name.isEmpty ? "Folder" : name,
                                                    mode: mode, includeHidden: hidden, tab: tab) {
                transfers.notice(message, action: mode == .copy ? "COPY" : "MOVE", place: name)
            }
        }
    }

    private func startTransfer(_ sources: [BrowseLocation], to destination: BrowseLocation, name: String) {
        // Through the same path as a drop, so an existing file prompts Replace / Keep Both.
        // Files from Finder come from no tab: theirs is the one showing them (TransferManager.tabID).
        let hidden = active?.showHidden ?? false
        Task {
            if let message = await operations.place(sources, into: destination, destinationName: name.isEmpty ? "Folder" : name,
                                                    mode: .copy, includeHidden: hidden) {
                transfers.notice(message, action: "TRANSFER", place: name)
            }
        }
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
            Button("New Folder", systemImage: "folder.badge.plus") { active?.newFolder() }
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
        for folder in sidebar.cloudFolders {
            add(.local(folder.url), folder.name, folder.host ?? folder.name, folder.symbol, .drive)
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

    /// The tabs for the File and Window menus (plain values: the menus update
    /// with focused values, not with the tabs themselves).
    private var tabsState: TabsState {
        let tabs = PaneTabs.shared
        return TabsState(titles: tabs.tabs.map { $0.title(twoPanes: showSecondPane, servers: servers) },
                         selected: tabs.selectedIndex ?? 0)
    }

    /// The browser that sidebar picks, ⌘K and the toolbar act on.
    private var active: BrowserModel? { showSecondPane && secondActive ? secondBrowser : browser }

    /// Something that takes typing is up: the rename field, the toolbar search,
    /// or a sheet. Edit menu commands stay enabled then, so ⌘X/⌘C/⌘V route
    /// into the text instead of going dead (PRD R2.12).
    private var textSurfaceUp: Bool {
        if searchFocused || showPalette { return true }
        if editing != nil || nasShare != nil { return true }
        if !transfers.pendingExternalFiles.isEmpty { return true }
        if PaneTabs.shared.renamingID != nil { return true }
        let models: [BrowserModel?] = [browser, secondBrowser]
        for case let model? in models {
            if model.renaming != nil || model.showGoToFolder { return true }
            if model.batchRenameItems != nil || model.infoItem != nil || model.editBackupFolders != nil || model.cardImport != nil { return true }
            if model.trustRequest != nil || model.passwordRequest != nil { return true }
        }
        return false
    }

    /// The shown tab's panes: two cards in a gutter, or the one list.
    @ViewBuilder private func panes(_ browser: BrowserModel) -> some View {
        if showSecondPane, let secondBrowser {
            HSplitView {
                pane(browser, side: .first, isActive: !secondActive) { secondActive = false }
                pane(secondBrowser, side: .second, isActive: secondActive) { secondActive = true }
            }
            .padding(.horizontal, 3)
            .padding(.bottom, 3)
            // The gutter the two cards sit in (the tab bar shares it).
            .background(Color.black.opacity(0.10))
        } else {
            FileListView(browser: browser)
        }
    }

    /// One pane of the two-pane layout: a card with a header naming the folder
    /// and what it's on. The active card has an accent ring, and a chip on its
    /// inner edge points the way F5 and F6 send.
    private func pane(_ model: BrowserModel, side: PaneSide, isActive: Bool, activate: @escaping () -> Void) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: paneSymbol(model)).foregroundStyle(isActive ? Color.accentColor : .secondary)
                Text(model.title.isEmpty ? " " : model.title)
                    .fontWeight(.semibold)
                    .foregroundStyle(isActive ? .primary : .secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let badge = paneBadge(model) {
                    Text(badge)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
                        .lineLimit(1)
                        .fixedSize()
                }
                Spacer(minLength: 0)
                // Where F5 / F6 send from here: the other pane's folder.
                if isActive, let other = Panes.shared.other(than: model), !other.title.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: side == .first ? "arrowtriangle.right.fill" : "arrowtriangle.left.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 15, height: 15)
                            .background(Color.accentColor, in: Circle())
                        Text(other.title).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .layoutPriority(-1)
                    .help("F5 copies and F6 moves the selection to “\(other.title)”")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Sends to \(other.title)")
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(isActive ? Color.accentColor.opacity(0.10) : Color.clear)
            .contentShape(Rectangle())
            .help(model.subtitle)
            .onTapGesture {
                // Activating from the header also hands the pane the keyboard,
                // so the arrows don't keep moving the other pane's selection.
                activate()
                model.requestKeyboardFocus()
            }
            Divider()
            // Clicks in the list make its pane the active one (BrowserModel.onInteraction).
            FileListView(browser: model, isSecondPane: side == .second)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isActive ? Color.accentColor.opacity(0.8) : Color(nsColor: .separatorColor), lineWidth: isActive ? 1.5 : 0.5)
        }
        .padding(5)
        // Both panes start the same width (the divider still moves).
        .frame(minWidth: 280, idealWidth: 10_000, maxWidth: .infinity)
    }

    /// The sidebar highlights the active pane's place when it has a row for
    /// it, and nothing otherwise (never a place neither pane shows).
    private func followActivePane() {
        let location = active?.current
        guard location != selection else { return }
        let listed = location.map { location in
            sidebar.favorites.contains { $0.location == location }
                || servers.browsable.contains { $0.startLocation == location }
                || sidebar.drives.contains { BrowseLocation.local($0.url) == location }
                || sidebar.cloudFolders.contains { BrowseLocation.local($0.url) == location }
                || sidebar.networkShares.contains { BrowseLocation.local($0.url) == location }
        } ?? false
        selection = listed ? location : nil
    }

    private func paneSymbol(_ model: BrowserModel) -> String {
        guard let current = model.current else { return "folder" }
        if current.serverID != nil { return "server.rack" }
        if let url = current.localURL, let cloud = CloudFolders.folder(containing: url) { return cloud.symbol }
        if let url = current.localURL, VolumeKinds.isNetwork(url) { return "externaldrive.connected.to.line.below" }
        return "folder"
    }

    /// What the pane's folder is on: the server, "NAS · Media" (with the
    /// verified shield when copies there are checked on the NAS), the drive's
    /// name, or Mac for the startup disk.
    private func paneBadge(_ model: BrowserModel) -> String? {
        guard let current = model.current else { return nil }
        if case .remote(let id, _) = current { return servers.server(id)?.displayName ?? "Server" }
        guard let url = current.localURL else { return nil }
        if let cloud = CloudFolders.folder(containing: url) { return cloud.name }
        let root = FreeSpace.volumeRoot(of: url)
        let volumeName = (root as NSString).lastPathComponent
        if VolumeKinds.isNetwork(url) {
            let verified = servers.nasLogin(forMount: root) != nil
            return "NAS · " + volumeName + (verified ? " ◆" : "")
        }
        if root == "/" { return "Mac" }
        return url.lexicalPath == root ? "Drive" : volumeName
    }

    private func openSecondPaneIfNeeded() {
        guard let tab else { return }
        if tab.second == nil { tab.second = makeBrowser() }
        guard let second = tab.second, second.current == nil, !tab.secondOpened else { return }
        tab.secondOpened = true
        let start = tab.pendingSecond.flatMap { PaneMemory.isReachable($0, servers: servers) ? $0 : nil }
            ?? sidebar.favorites.dropFirst().first(where: sidebar.isAvailable)?.location
            ?? sidebar.networkShares.first.map { .local($0.url) }
            ?? .local(FileManager.default.homeDirectoryForCurrentUser)
        // A tick later: the pane's table is being created in this same update.
        Task { second.open(start) }
    }

    /// A tab being shown: a new or restored one opens its folders (a saved one
    /// that can't be reached falls back, as at launch); one shown before gets
    /// its scroll back. The keyboard goes to its active pane.
    private func tabShown() {
        guard let tab else { return }
        // The HUD follows the tab: a transfer picked in the queue list doesn't stay pinned.
        transfers.pinnedJobID = nil
        if tab.first.current == nil, !tab.firstOpened {
            tab.firstOpened = true
            let start = tab.pendingFirst.flatMap { PaneMemory.isReachable($0, servers: servers) ? $0 : nil }
                ?? sidebar.favorites.first(where: sidebar.isAvailable)?.location
                ?? sidebar.drives.first(where: { !$0.isInternal }).map { .local($0.url) }
                ?? .local(FileManager.default.homeDirectoryForCurrentUser)
            let first = tab.first
            Task { first.open(start) }
        }
        if showSecondPane { openSecondPaneIfNeeded() }
        (showSecondPane && tab.secondActive ? tab.second : tab.first)?.requestKeyboardFocus()
    }

    private func makeBrowser() -> BrowserModel {
        BrowserModel(servers: servers, connections: connections, operations: operations)
    }

    /// The full HUD is showing (a file operation taking the slot shows the strip).
    /// The toolbar search edits the active pane's filter.
    private var searchBinding: Binding<String> {
        Binding(get: { active?.searchText ?? "" }, set: { active?.searchText = $0 })
    }

    private var searchPrompt: String {
        let name = active?.current?.lastComponent ?? ""
        return name.isEmpty ? "Search" : "Search “\(name)”"
    }

    private var showsExpandedHUD: Bool { transfers.isExpanded && !(transfers.featured?.isOperation ?? true) && hasRoomForFullHUD }

    /// The full HUD (about 285 pt) leaves each list its header, about six rows
    /// and its path bar; a shorter window keeps the strip (a click still asks).
    private var hasRoomForFullHUD: Bool { detailHeight >= 285 + 250 }

    /// Makes `model`'s pane the active one (clicked, right-clicked or focused),
    /// and gives its table the keyboard: a right-click never moves AppKit focus
    /// on its own, and Space/arrows must follow the pane the menu opened in.
    private func activate(_ model: BrowserModel) {
        guard showSecondPane else { return }
        if model === secondBrowser {
            secondActive = true
        } else if model === browser {
            secondActive = false
        }
        model.requestKeyboardFocus()
    }

    /// Refresh whichever panes show a folder that changed, in any tab: a
    /// transfer's destination (and a move's sources), or a file operation's folders.
    private func wireRefresh() {
        let refresh: ([BrowseLocation]) -> Void = { folders in
            BrowserModel.reloadWhenIdle(PaneTabs.shared.allBrowsers.filter { model in folders.contains(where: model.shows) })
        }
        operations.onChanged = refresh
        transfers.onFinished = { job in
            refresh([.local(job.destination)] + (job.deleteSources ? job.sources.compactMap(\.parent) : []))
        }
    }

    private func start() {
        PaneTabs.shared.makeBrowser = { [servers, connections, operations] in
            BrowserModel(servers: servers, connections: connections, operations: operations)
        }
        // Two panes by default (0.2.22): switched on once for existing installs too.
        if !TransferManager.isIsolated, !UserDefaults.standard.bool(forKey: "twoPanesByDefault") {
            UserDefaults.standard.set(true, forKey: "twoPanesByDefault")
            showSecondPane = true
        }
        PaneTabs.shared.startIfNeeded()
        Panes.shared.twoPanes = showSecondPane
        BrowserModel.oppositePane = { Panes.shared.other(than: $0) }
        BrowserModel.swapPanes = { Panes.shared.swap() }
        BrowserModel.active = active
        BrowserModel.onInteraction = { model in activate(model) }
        // Copy To ▸ / Move To ▸: favorite folders (NAS first), then NAS shares.
        BrowserModel.destinations = { [sidebar] in
            let favorites = sidebar.favorites.filter { sidebar.isAvailable($0) }.compactMap(\.location.localURL)
            let ordered = favorites.filter(VolumeKinds.isNetwork) + favorites.filter { !VolumeKinds.isNetwork($0) }
            var places = ordered.map { url in
                (name: url.lastPathComponent, detail: sidebar.volumeName(for: url).flatMap { $0 == url.lastPathComponent ? nil : $0 },
                 location: BrowseLocation.local(url))
            }
            for share in sidebar.networkShares where !favorites.contains(where: { $0.lexicalPath == share.url.lexicalPath }) {
                places.append((name: share.name, detail: share.host, location: .local(share.url)))
            }
            return places
        }
        operations.undoManager = undoManager
        operations.onUndoProblem = { message in transfers.notice(message, action: "UNDO") }
        transfers.restoreQueue()
        if NotificationRouter.shared.openMainWindow == nil { NotificationRouter.shared.openMainWindow = openWindow }
        #if DEBUG
        transfers.startFakeTransferIfRequested()
        UITestHarness.runQueueTestIfRequested(transfers: transfers)
        UITestHarness.runClearQueueTestIfRequested(transfers: transfers)
        UITestHarness.renderStripIfRequested(transfers: transfers)
        UITestHarness.runHUDKeysTestIfRequested(transfers: transfers)
        UITestHarness.runNoticeTestIfRequested(transfers: transfers)
        UITestHarness.runStatusTestIfRequested(transfers: transfers)
        UITestHarness.runConflictTestIfRequested(transfers: transfers)
        UITestHarness.runCableTestIfRequested(transfers: transfers)
        UITestHarness.runCableLiveTestIfRequested(transfers: transfers)
        UITestHarness.runBusyTestIfRequested(transfers: transfers)
        UITestHarness.runQueueClickTestIfRequested(transfers: transfers)
        UITestHarness.runFollowTabTestIfRequested(transfers: transfers)
        UITestHarness.runReloadDragTestIfRequested(transfers: transfers)
        UITestHarness.renderFullDiskAccessIfRequested(transfers: transfers)
        UITestHarness.runTabSwitchTestIfRequested()
        UITestHarness.runTabPressTestIfRequested()
        UITestHarness.runTableMetricsTestIfRequested()
        UITestHarness.runNativeCellsTestIfRequested(transfers: transfers)
        UITestHarness.runNativeKeysTestIfRequested()
        UITestHarness.runNativeDropTestIfRequested(transfers: transfers)
        UITestHarness.runNestedMoveTestIfRequested(transfers: transfers)
        UITestHarness.runRenameStealTestIfRequested()
        UITestHarness.runSpaceTestIfRequested()
        UITestHarness.runActivePaneProbeIfRequested()
        UITestHarness.runEditBackupTestIfRequested(transfers: transfers)
        UITestHarness.runCardImportTestIfRequested(transfers: transfers)
        UITestHarness.runNativeHardeningTestIfRequested(transfers: transfers)
        UITestHarness.runRenameScrollTestIfRequested()
        UITestHarness.runNewSinceTestIfRequested()
        UITestHarness.runCompareTestIfRequested()
        UITestHarness.runVideoColumnTestIfRequested()
        UITestHarness.runDropSpaceTestIfRequested()
        UITestHarness.runFolderSummaryTestIfRequested()
        UITestHarness.runMonthlyTotalsTestIfRequested()
        UITestHarness.runFinishTestIfRequested(transfers: transfers)
        UITestHarness.runSuggestTestIfRequested()
        UITestHarness.runImportTestIfRequested(servers: servers)
        UITestHarness.runWelcomeTestIfRequested()
        UITestHarness.runWatchTestIfRequested(servers: servers, connections: connections)
        UITestHarness.runTuneTestIfRequested()
        UITestHarness.runMenuRenameTestIfRequested(transfers: transfers)
        UITestHarness.runRenameByHandIfRequested(transfers: transfers)
        UITestHarness.runTorrentStatusTestIfRequested()
        UITestHarness.runTorrentStatusRealIfRequested(servers: servers)
        UITestHarness.runArrivalTestIfRequested(servers: servers)
        UITestHarness.runMissingEpisodesTestIfRequested(transfers: transfers)
        UITestHarness.runWelcomeBackTestIfRequested(transfers: transfers)
        UITestHarness.runEnterLicenseTestIfRequested()
        UITestHarness.runSeedboxProbeIfRequested(servers: servers, connections: connections)
        UITestHarness.runVerifyTestIfRequested(transfers: transfers)
        UITestHarness.runHashProgressTestIfRequested(transfers: transfers)
        UITestHarness.runMenuBarTestIfRequested(transfers: transfers)
        UITestHarness.runNotificationTextTestIfRequested()
        UITestHarness.runTrashTestIfRequested(transfers: transfers)
        UITestHarness.runOpenWithTestIfRequested()
        UITestHarness.runOpenWithMenuTestIfRequested()
        // -BlitShowAcknowledgements: About Blit and its Acknowledgements window, for a picture.
        if UserDefaults.standard.bool(forKey: "BlitShowAcknowledgements") {
            openWindow(id: "about")
            openWindow(id: "acknowledgements")
        }
        // -BlitShowTransferLog: Window › Transfer Log, for a picture.
        if UserDefaults.standard.bool(forKey: "BlitShowTransferLog") { openWindow(id: "transfer-log") }
        UITestHarness.runMediaExtensionTestIfRequested()
        UITestHarness.runDropTestIfRequested()
        UITestHarness.runSidebarDropTestIfRequested(sidebar: sidebar)
        UITestHarness.runAutoCollapseTestIfRequested(transfers: transfers)
        UITestHarness.runDragOutTestIfRequested()
        UITestHarness.runTwoPaneTestIfRequested()
        UITestHarness.runLayoutShotIfRequested()
        UITestHarness.runTabsTestIfRequested()
        UITestHarness.runTabsRestoreTestIfRequested()
        UITestHarness.runTabsKeysTestIfRequested()
        UITestHarness.runTabsDragTestIfRequested()
        UITestHarness.runEmptyClickTestIfRequested()
        UITestHarness.runRowDragTestIfRequested()
        UITestHarness.runRowDragRealTestIfRequested()
        UITestHarness.runRemoteDragTestIfRequested(servers: servers, transfers: transfers)
        UITestHarness.runCloudTestIfRequested(operations: operations, transfers: transfers)
        UITestHarness.renderProductImageIfRequested(transfers: transfers)
        UITestHarness.renderCardIfRequested(transfers: transfers)
        UITestHarness.runDemoShotIfRequested(sidebar: sidebar, transfers: transfers)
        UITestHarness.runDemoVideoIfRequested(sidebar: sidebar, transfers: transfers)
        UITestHarness.runLicenseTestIfRequested(transfers: transfers)
        UITestHarness.runHUDHeightTestIfRequested(transfers: transfers)
        UITestHarness.runRetryNowTestIfRequested(transfers: transfers)
        UITestHarness.runBatchRenameTestIfRequested(transfers: transfers)
        UITestHarness.runDiskBoundTestIfRequested(transfers: transfers)
        UITestHarness.runSpaceTestIfRequested(transfers: transfers)
        UITestHarness.runExistsTestIfRequested(transfers: transfers)
        UITestHarness.runStructureTestIfRequested(transfers: transfers)
        UITestHarness.runLaneTestIfRequested(transfers: transfers)
        #endif
        connections.warmUp(servers.browsable)
        Task { await LicenseManager.shared.revalidateIfDue() }
        #if DEBUG
        UITestHarness.runLinkTestIfRequested(connections: connections, servers: servers)
        UITestHarness.runShareTestIfRequested(sidebar: sidebar)
        #endif
        wireRefresh()
        // The shown tab's folders (a window made again keeps its tabs).
        tabShown()
        // First launch: the Welcome on a fresh install (Full Disk Access is one
        // of its steps), else Full Disk Access once, after the window is up.
        if Welcome.shouldShow(servers: servers.servers, favorites: sidebar.favorites) {
            Task {
                try? await Task.sleep(for: .seconds(1))
                showingWelcome = true
            }
        } else if FullDiskAccess.shared.shouldOffer {
            Task {
                try? await Task.sleep(for: .seconds(1))
                offeringFullDiskAccess = true
            }
        }
    }
}

/// The tabs are saved for next launch as their folders change, and the
/// sidebar follows the active pane (a modifier of its own, to keep
/// ContentView's body checkable).
private struct PaneTracking: ViewModifier {
    let tabID: UUID?
    let first: BrowseLocation?
    let second: BrowseLocation?
    let secondActive: Bool
    let follow: () -> Void
    let shown: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: first) {
                PaneTabs.shared.save()
                follow()
            }
            .onChange(of: second) {
                PaneTabs.shared.save()
                follow()
            }
            .onChange(of: secondActive) {
                PaneTabs.shared.save()
                follow()
            }
            .onChange(of: tabID) {
                shown()
                follow()
            }
    }
}

/// The first or second pane of a two-pane window.
enum PaneSide: Hashable {
    case first, second
}

/// Hands over the window hosting a view (for key handling that needs it).
/// Tiny and invisible to the mouse, so it never takes clicks or right-clicks
/// meant for the views around it.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    final class PassthroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView {
        let view = PassthroughView()
        DispatchQueue.main.async { onWindow(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onWindow(view.window) }
    }
}

/// Window-level bookkeeping for the panes: which one keys and Space go to,
/// one Quick Look at a time, and the undo manager for file operations.
private struct PaneCoordination: ViewModifier {
    let tabID: UUID?
    let browser: BrowserModel?
    let secondBrowser: BrowserModel?
    let active: BrowserModel?
    let secondActive: Bool
    let showSecondPane: Bool
    let undoManager: UndoManager?
    let operations: FileOperations

    func body(content: Content) -> some View {
        content
            .onChange(of: secondActive) { BrowserModel.active = active }
            .onChange(of: tabID) { BrowserModel.active = active }
            .onChange(of: showSecondPane) { BrowserModel.active = active }
            // A pane's model can come later (a tab's second pane is made when first shown).
            .onChange(of: active.map(ObjectIdentifier.init)) { BrowserModel.active = active }
            .onChange(of: undoManager) { _, manager in operations.undoManager = manager }
            .onChange(of: browser?.previewURL) { _, url in if url != nil { secondBrowser?.previewURL = nil } }
            .onChange(of: secondBrowser?.previewURL) { _, url in if url != nil { browser?.previewURL = nil } }
            .focusedSceneValue(\.browser, active)
    }
}

/// File › Import Servers… and the sidebar's +: the import sheet (PRD R1.8),
/// selecting the first server brought in.
private struct ImportServersHost: ViewModifier {
    @Binding var importing: Bool
    @Binding var selection: BrowseLocation?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .blitImportServers)) { _ in importing = true }
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .blitCloseImportServers)) { _ in importing = false }
            #endif
            .sheet(isPresented: $importing) {
                ImportServersView { imported in
                    if let first = imported.first { selection = first.startLocation }
                }
            }
    }
}

/// Help › Welcome to Blit… and the first launch: the Welcome (PRD R2.24).
private struct WelcomeHost: ViewModifier {
    @Binding var showing: Bool
    @State private var step = WelcomeView.Step.welcome

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .blitShowWelcome)) { note in
                step = (note.object as? Int).flatMap(WelcomeView.Step.init(rawValue:)) ?? .welcome
                showing = true
            }
            #if DEBUG
            .onReceive(NotificationCenter.default.publisher(for: .blitCloseImportServers)) { _ in showing = false }
            #endif
            .sheet(isPresented: $showing) { WelcomeView(step: step) }
    }
}
