// Standard macOS sidebar: Favorites (drag folders in, reorder, ⌘D), Servers,
// Drives and NAS shares (PRD R2.9).

import BlitSFTP
import SwiftUI

struct SidebarView: View {
    @Environment(SidebarModel.self) private var sidebar
    @Environment(ServerStore.self) private var servers
    @Environment(ConnectionManager.self) private var connections
    @Binding var selection: BrowseLocation?
    @State private var favoritesTargeted = false
    @State private var collapsedDevices = Set<String>()
    var onAddServer: () -> Void
    var onEditServer: (ServerConfig) -> Void
    var onRemoveServer: (ServerConfig) -> Void
    var onTransfer: ([BrowseLocation], BrowseLocation, String) -> Void
    var onNASVerification: (VolumeLocation) -> Void
    /// Refresh (reload whatever shows this location, or open it); `reconnect`
    /// first reopens the server's session.
    var onRefresh: (BrowseLocation, _ reconnect: Bool) -> Void

    var body: some View {
        List(selection: $selection) {
            Section("Favorites") {
                ForEach(sidebar.favorites) { favorite in
                    FavoriteRow(favorite: favorite)
                        .transferTarget(favorite.location, name: favorite.location.lastComponent, onTransfer: onTransfer)
                        .tag(favorite.location)
                }
                .onMove { sidebar.moveFavorites(from: $0, to: $1) }
                .onInsert(of: [.blitLocations, .fileURL]) { index, providers in
                    sidebar.addDropped(providers, at: index)
                }
                if sidebar.favorites.isEmpty {
                    Text(favoritesTargeted ? "Drop to add to Favorites" : "Drag folders here")
                        .font(.callout)
                        .foregroundStyle(favoritesTargeted ? .primary : .tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .selectionDisabled()
                        .onDrop(of: [.blitLocations, .fileURL], isTargeted: $favoritesTargeted) { providers in
                            sidebar.addDropped(providers)
                            return true
                        }
                }
            }

            Section {
                ForEach(servers.browsable) { server in
                    HStack {
                        Label(server.displayName, systemImage: "server.rack")
                        Spacer(minLength: 4)
                        StatusDot(state: connections.state(server), link: connections.links[server.id]?.summary)
                    }
                    .transferTarget(server.startLocation, name: server.displayName, onTransfer: onTransfer)
                    .tag(server.startLocation)
                }
                if servers.browsable.isEmpty {
                    Button("Add Server…", action: onAddServer)
                        .buttonStyle(.link)
                        .selectionDisabled()
                }
            } header: {
                HStack {
                    Text("Servers")
                    Spacer()
                    Button(action: onAddServer) { Image(systemName: "plus") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Add Server")
                }
            }

            Section("Drives") {
                ForEach(sidebar.drives) { drive in
                    Label(drive.name, systemImage: drive.isInternal ? "internaldrive" : "externaldrive")
                        .transferTarget(.local(drive.url), name: drive.name, onTransfer: onTransfer)
                        .tag(BrowseLocation.local(drive.url))
                }
            }

            if !sidebar.networkDevices.isEmpty {
                Section("Network") {
                    ForEach(sidebar.networkDevices) { device in
                        DisclosureGroup(isExpanded: expansion(for: device)) {
                            ForEach(device.shares) { share in
                                shareRow(share)
                            }
                        } label: {
                            Label(device.name, systemImage: device.symbol)
                                .help(device.model.map { "\(device.name) (\($0))" } ?? device.name)
                                .selectionDisabled()
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // One menu for the whole list, built for the row that was right-clicked.
        // (Per-row menus didn't open on some rows in the selectable sidebar.)
        .contextMenu(forSelectionType: BrowseLocation.self) { locations in
            if locations.count == 1, let location = locations.first {
                menu(for: location)
            }
        }
    }

    /// The right-click menu for a sidebar row, by what the row is.
    @ViewBuilder private func menu(for location: BrowseLocation) -> some View {
        if let server = servers.browsable.first(where: { $0.startLocation == location }) {
            Button("Refresh") { onRefresh(location, false) }
            Button("Reconnect") { onRefresh(location, true) }
            Divider()
            Button("Edit…") { onEditServer(server) }
            Button("Disconnect") { connections.disconnect(server) }
                .disabled(connections.state(server) != .connected)
            Divider()
            Button("Add to Favorites") { sidebar.addFavorite(location) }
                .disabled(sidebar.isFavorite(location))
            Divider()
            Button("Remove…", role: .destructive) { onRemoveServer(server) }
        } else if let favorite = sidebar.favorites.first(where: { $0.location == location }) {
            Button("Refresh") { onRefresh(location, false) }
                .disabled(!sidebar.isAvailable(favorite))
            Divider()
            if let url = location.localURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .disabled(!sidebar.isAvailable(favorite))
            }
            Button("Remove from Favorites") { sidebar.removeFavorite(favorite) }
        } else if let url = location.localURL {
            Button("Refresh") { onRefresh(location, false) }
            Divider()
            if let share = sidebar.networkShares.first(where: { $0.url == url }) {
                let login = servers.nasLogin(forMount: share.url.path)
                Button(login == nil ? "Verify Copies on NAS…" : "NAS Verification…") { onNASVerification(share) }
                if let login {
                    Button("Turn Off NAS Verification") { servers.remove(login) }
                }
                Divider()
            }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            // Drives and shares can be favorites too (their top level).
            Button("Add to Favorites") { sidebar.addFavorite(location) }
                .disabled(sidebar.isFavorite(location))
        }
    }

    /// Network devices start expanded; collapsing is remembered for the session.
    private func expansion(for device: NetworkDevice) -> Binding<Bool> {
        Binding(get: { !collapsedDevices.contains(device.name) },
                set: { expanded in
                    if expanded { collapsedDevices.remove(device.name) } else { collapsedDevices.insert(device.name) }
                })
    }

    @ViewBuilder private func shareRow(_ share: VolumeLocation) -> some View {
        Group {
            let login = servers.nasLogin(forMount: share.url.path)
            HStack {
                Label(share.name, systemImage: "externaldrive.connected.to.line.below")
                Spacer(minLength: 4)
                if login != nil {
                    Image(nsImage: PixelArt.image(PixelArt.shield, cell: 1))
                        .foregroundStyle(.secondary)
                        .help("Copies here are verified with sha256sum on the NAS")
                        .accessibilityLabel("Verified on the NAS")
                }
            }
            .transferTarget(.local(share.url), name: share.name, onTransfer: onTransfer)
            .tag(BrowseLocation.local(share.url))
        }
    }
}

/// Makes a sidebar row accept dragged files and folders (PRD R2.10).
private struct TransferTarget: ViewModifier {
    let location: BrowseLocation
    let name: String
    let onTransfer: ([BrowseLocation], BrowseLocation, String) -> Void
    @State private var isTargeted = false

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .dropDestination(for: TransferPayload.self) { payloads, _ in
                let sources = payloads.flatMap(\.locations).uniqued()
                guard !sources.isEmpty else { return false }
                onTransfer(sources, location, name)
                return true
            } isTargeted: { isTargeted = $0 }
            // Drawn inside the row: a sidebar row clips anything past its edges,
            // which hid the old outline (drawn 3 pt outside) entirely.
            .background {
                if showsTarget {
                    RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.22)).padding(-2)
                }
            }
            .overlay {
                if showsTarget {
                    PixelMarchingAnts(cell: 1.5).padding(.horizontal, -1).padding(.vertical, 0)
                }
            }
    }

    private var showsTarget: Bool { isTargeted }
}

extension View {
    func transferTarget(_ location: BrowseLocation, name: String,
                        onTransfer: @escaping ([BrowseLocation], BrowseLocation, String) -> Void) -> some View {
        modifier(TransferTarget(location: location, name: name, onTransfer: onTransfer))
    }
}

private struct FavoriteRow: View {
    @Environment(SidebarModel.self) private var sidebar
    @Environment(ServerStore.self) private var servers
    let favorite: Favorite

    var body: some View {
        let available = sidebar.isAvailable(favorite)
        HStack {
            Label(name, systemImage: available ? symbol : "folder.badge.questionmark")
            Spacer(minLength: 4)
            if let badge {
                Text(badge).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .foregroundStyle(available ? .primary : .tertiary)
        .help(available ? path : "\(path) isn't available")
    }

    private var name: String {
        if let volume = volume { return volume.name }
        let last = favorite.location.lastComponent
        if last.isEmpty { return servers.server(favorite.location.serverID)?.displayName ?? "Server" }
        return last
    }

    /// The drive or share itself, when the favorite is a volume's top level.
    private var volume: VolumeLocation? {
        guard let url = favorite.location.localURL?.standardizedFileURL else { return nil }
        return (sidebar.drives + sidebar.networkShares).first { $0.url.standardizedFileURL.path == url.path }
    }

    private var symbol: String {
        guard let volume else { return "folder" }
        if sidebar.networkShares.contains(volume) { return "externaldrive.connected.to.line.below" }
        return volume.isInternal ? "internaldrive" : "externaldrive"
    }

    /// The volume or server it lives on.
    /// The volume or server it lives on; for a volume itself, the device
    /// serving a share (a drive needs none), and nothing for a server's home.
    private var badge: String? {
        if let volume { return volume.host }
        switch favorite.location {
        case .local(let url): return sidebar.volumeName(for: url)
        case .remote(let id, let bytes): return bytes.isEmpty ? nil : servers.server(id)?.displayName
        }
    }

    private var path: String {
        switch favorite.location {
        case .local(let url): return url.path
        case .remote(let id, let bytes):
            return "\(servers.server(id)?.displayName ?? "server"):\(RemotePath(bytes: bytes))"
        }
    }
}

/// A server's browsing connection as pixel signal bars (the one pixel-art
/// touch outside the HUD): all lit when connected, filling in a loop while
/// connecting, dim when not connected, a pixel ✕ in muted red on failure.
private struct StatusDot: View {
    let state: ConnectionState
    /// "148 ms · en7" once measured.
    var link: String?

    var body: some View {
        switch state {
        case .connected:
            let detail = link.map { $0.isEmpty ? "" : " · \($0)" } ?? ""
            PixelSignal(lit: 4).help("Connected" + detail)
                .accessibilityLabel("Connected" + detail)
        case .connecting:
            TimelineView(.periodic(from: .now, by: 0.18)) { context in
                PixelSignal(lit: Int(context.date.timeIntervalSinceReferenceDate / 0.18) % 5)
            }
            .help("Connecting…")
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Connecting")
        case .failed(let why):
            Image(nsImage: PixelGlyph.cross.image(size: 10.5))
                .foregroundStyle(Color.failure)
                .help(why)
                .accessibilityLabel("Connection failed: \(why)")
        case .idle:
            PixelSignal(lit: 0).help("Not connected · opens when you click the server")
                .accessibilityLabel("Not connected")
        }
    }
}

/// Four pixel bars (heights 1, 3, 5, 7 on a 7×7 grid), `lit` of them bright.
struct PixelSignal: View {
    let lit: Int
    /// Points per pixel: 1.5 is 3 device pixels on Retina, so edges stay crisp.
    var cell: CGFloat = 1.5

    var body: some View {
        Canvas { context, _ in
            for bar in 0..<4 {
                let height = bar * 2 + 1
                for y in (7 - height)..<7 {
                    let rect = CGRect(x: CGFloat(bar * 2) * cell, y: CGFloat(y) * cell, width: cell, height: cell)
                    context.fill(Path(rect), with: bar < lit ? .style(.primary) : .style(.tertiary))
                }
            }
        }
        .frame(width: 7 * cell, height: 7 * cell)
        .accessibilityLabel("Signal")
        .accessibilityValue("\(lit) of 4 bars")
    }
}

extension Color {
    /// Muted red, used only for failures (PRD Visual language): fills, tags, glyphs.
    static let failure = Color(red: 0xB3 / 255, green: 0x5C / 255, blue: 0x5C / 255)
    /// The same red for failure text: #b35c5c in light mode (4.6:1 on white),
    /// its lighter tint #C98080 in dark mode, where #b35c5c falls under 4.5:1.
    static let failureText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0xC9 / 255, green: 0x80 / 255, blue: 0x80 / 255, alpha: 1)
            : NSColor(red: 0xB3 / 255, green: 0x5C / 255, blue: 0x5C / 255, alpha: 1)
    })
}
