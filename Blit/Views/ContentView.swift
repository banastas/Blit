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
    @State private var browser: BrowserModel?
    /// The optional second pane (R2.8) and which pane sidebar picks, ⌘K and
    /// the toolbar act on (the one last clicked).
    @State private var secondBrowser: BrowserModel?
    @State private var secondActive = false
    /// Which pane's table has the keyboard. Every way of activating a pane
    /// (click, right-click, the header, Tab) moves the keyboard here too, so
    /// arrows and ⌘⌫ always agree on the pane the user is looking at.
    @FocusState private var focusedPane: PaneFocus?
    @AppStorage("showSecondPane") private var showSecondPane = false
    @State private var nasShare: VolumeLocation?
    @State private var showPalette = false
    @FocusState private var searchFocused: Bool
    @State private var selection: BrowseLocation?
    @State private var editing: EditingServer?
    @State private var removing: ServerConfig?
    /// Height of the floating transfer HUD or strip, reserved below the list.
    @State private var hudHeight: CGFloat = 0

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
                            pane(browser, tag: .first, isActive: !secondActive) { secondActive = false }
                            pane(secondBrowser, tag: .second, isActive: secondActive) { secondActive = true }
                        }
                    } else {
                        FileListView(browser: browser)
                    }
                }
                    // Room at the bottom for the transfer HUD, which floats over it.
                    .safeAreaPadding(.bottom, transfers.featured == nil ? 0 : hudHeight)
                    .overlay(alignment: .bottom) {
                        // An overlay, not a safe-area inset: overlays don't take part in
                        // sizing the window. As an inset, every HUD update (the percent
                        // ticking during a download) re-sized the window's content,
                        // macOS briefly reported a shorter toolbar, and the list and
                        // HUD jumped.
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
        .navigationTitle(active?.title ?? "Blit")
        .navigationSubtitle(active?.subtitle ?? "")
        .toolbar { toolbar }
        // Search the folder in the active pane (⌘F), as in Finder's toolbar.
        .searchable(text: searchBinding, placement: .toolbar, prompt: searchPrompt)
        .searchFocused($searchFocused)
        .onReceive(NotificationCenter.default.publisher(for: .blitFocusSearch)) { _ in searchFocused = true }
        .onReceive(NotificationCenter.default.publisher(for: .blitShowPalette)) { _ in showPalette = true }
        .onChange(of: selection) { _, location in
            // A tick later: the sidebar's list can still be mid-update when its
            // selection changes, and reloading a pane's table from inside that
            // update re-enters the table's delegate.
            guard let location else { return }
            let pane = active
            Task { pane?.open(location) }
        }
        .onChange(of: showSecondPane) { _, shown in
            if shown { openSecondPaneIfNeeded() } else { secondActive = false }
        }
        .onAppear(perform: start)
        .background(alignment: .topLeading) {
            WindowReader { BrowserModel.activeWindow = $0 }
                .frame(width: 1, height: 1)
                .allowsHitTesting(false)
        }
        .modifier(PaneCoordination(browser: browser, secondBrowser: secondBrowser, active: active,
                                   secondActive: secondActive, showSecondPane: showSecondPane,
                                   undoManager: undoManager, operations: operations))
        // Plain values, so View › Show/Hide Transfer Details updates with the HUD.
        .focusedSceneValue(\.transferDetails, TransferDetailsState(isExpanded: transfers.isExpanded,
                                                                  available: transfers.featured != nil))
        .focusedSceneValue(\.textSurface, textSurfaceUp)
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
        let mode: FileOperations.Mode = NSEvent.modifierFlags.contains(.option) ? .copy : .automatic
        let hidden = active?.showHidden ?? false
        Task {
            if let message = await operations.place(sources, into: destination, destinationName: name.isEmpty ? "Folder" : name,
                                                    mode: mode, includeHidden: hidden) {
                transfers.notice(message, action: mode == .copy ? "COPY" : "MOVE", place: name)
            }
        }
    }

    private func startTransfer(_ sources: [BrowseLocation], to destination: BrowseLocation, name: String) {
        // Through the same path as a drop, so an existing file prompts Replace / Keep Both.
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

    /// Something that takes typing is up: the rename field, the toolbar search,
    /// or a sheet. Edit menu commands stay enabled then, so ⌘X/⌘C/⌘V route
    /// into the text instead of going dead (PRD R2.12).
    private var textSurfaceUp: Bool {
        if searchFocused || showPalette { return true }
        if editing != nil || nasShare != nil { return true }
        if !transfers.pendingExternalFiles.isEmpty { return true }
        let models: [BrowserModel?] = [browser, secondBrowser]
        for case let model? in models {
            if model.renaming != nil || model.showGoToFolder { return true }
            if model.batchRenameItems != nil || model.infoItem != nil { return true }
            if model.trustRequest != nil || model.passwordRequest != nil { return true }
        }
        return false
    }

    /// One pane of the two-pane layout, with a small location header.
    private func pane(_ model: BrowserModel, tag: PaneFocus, isActive: Bool, activate: @escaping () -> Void) -> some View {
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
            .onTapGesture {
                // Activating from the header also hands the pane the keyboard,
                // so the arrows don't keep moving the other pane's selection.
                activate()
                focusedPane = tag
            }
            Divider()
            FileListView(browser: model, onFocus: activate, paneFocus: $focusedPane, paneTag: tag)
                .simultaneousGesture(TapGesture().onEnded(activate))
        }
        .frame(minWidth: 280)
    }

    private func openSecondPaneIfNeeded() {
        if secondBrowser == nil {
            let second = BrowserModel(servers: servers, connections: connections, operations: operations)
            secondBrowser = second
            wireRefresh(browser, second)
        }
        guard let secondBrowser, secondBrowser.current == nil else { return }
        let start = sidebar.favorites.dropFirst().first(where: sidebar.isAvailable)?.location
            ?? sidebar.networkShares.first.map { .local($0.url) }
            ?? .local(FileManager.default.homeDirectoryForCurrentUser)
        // A tick later: the pane's table is being created in this same update.
        Task { secondBrowser.open(start) }
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

    private var showsExpandedHUD: Bool { transfers.isExpanded && !(transfers.featured?.isOperation ?? true) }

    /// Makes `model`'s pane the active one (clicked, right-clicked or focused),
    /// and gives its table the keyboard: a right-click never moves AppKit focus
    /// on its own, and Space/arrows must follow the pane the menu opened in.
    private func activate(_ model: BrowserModel) {
        guard showSecondPane else { return }
        if model === secondBrowser {
            secondActive = true
            focusedPane = .second
        } else if model === browser {
            secondActive = false
            focusedPane = .first
        }
    }

    /// Refresh whichever panes show a folder that changed: a transfer's
    /// destination (and a move's sources), or a file operation's folders.
    /// Re-wired when the second pane is created, since the closure holds the
    /// panes that existed when it was made.
    private func wireRefresh(_ first: BrowserModel?, _ second: BrowserModel?) {
        let refresh: ([BrowseLocation]) -> Void = { [weak first, weak second] folders in
            for model in [first, second].compactMap({ $0 }) {
                if folders.contains(where: model.shows) { model.reload() }
            }
        }
        operations.onChanged = refresh
        transfers.onFinished = { job in
            refresh([.local(job.destination)] + (job.deleteSources ? job.sources.compactMap(\.parent) : []))
        }
    }

    private func start() {
        if browser == nil { browser = BrowserModel(servers: servers, connections: connections, operations: operations) }
        if showSecondPane { openSecondPaneIfNeeded() }
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
            for share in sidebar.networkShares where !favorites.contains(where: { $0.standardizedFileURL == share.url.standardizedFileURL }) {
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
        UITestHarness.renderStripIfRequested(transfers: transfers)
        UITestHarness.runHUDKeysTestIfRequested(transfers: transfers)
        UITestHarness.runNoticeTestIfRequested(transfers: transfers)
        UITestHarness.runStatusTestIfRequested(transfers: transfers)
        UITestHarness.runConflictTestIfRequested(transfers: transfers)
        UITestHarness.runVerifyTestIfRequested(transfers: transfers)
        UITestHarness.runHashProgressTestIfRequested(transfers: transfers)
        UITestHarness.runMenuBarTestIfRequested(transfers: transfers)
        UITestHarness.runNotificationTextTestIfRequested()
        UITestHarness.runTrashTestIfRequested(transfers: transfers)
        UITestHarness.runOpenWithTestIfRequested()
        UITestHarness.runMediaExtensionTestIfRequested()
        UITestHarness.runDropTestIfRequested()
        UITestHarness.runSidebarDropTestIfRequested(sidebar: sidebar)
        UITestHarness.runAutoCollapseTestIfRequested(transfers: transfers)
        UITestHarness.runDragOutTestIfRequested()
        UITestHarness.renderProductImageIfRequested(transfers: transfers)
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
        wireRefresh(browser, secondBrowser)
        if selection == nil {
            selection = sidebar.favorites.first(where: sidebar.isAvailable)?.location
                ?? sidebar.drives.first(where: { !$0.isInternal }).map { .local($0.url) }
                ?? .local(FileManager.default.homeDirectoryForCurrentUser)
        }
    }
}

/// Which pane of a two-pane window has the keyboard: the table focus, the pane
/// headers and right-clicks all move it, and activation follows it.
enum PaneFocus: Hashable {
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
            .onChange(of: showSecondPane) { BrowserModel.active = active }
            .onChange(of: undoManager) { _, manager in operations.undoManager = manager }
            .onChange(of: browser?.previewURL) { _, url in if url != nil { secondBrowser?.previewURL = nil } }
            .onChange(of: secondBrowser?.previewURL) { _, url in if url != nil { browser?.previewURL = nil } }
            .focusedSceneValue(\.browser, active)
    }
}
