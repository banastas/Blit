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
                        StatusDot(state: connections.state(server))
                    }
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
                    Image(systemName: "checkmark.shield")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Copies here are verified with sha256sum on the NAS")
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
            .overlay {
                if isTargeted {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                        .foregroundStyle(.primary)
                        .padding(-3)
                }
            }
    }
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
            Label(name, systemImage: available ? "folder" : "folder.badge.questionmark")
            Spacer(minLength: 4)
            if let badge {
                Text(badge).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
        }
        .foregroundStyle(available ? .primary : .tertiary)
        .help(available ? path : "\(path) isn't available")
    }

    private var name: String {
        let last = favorite.location.lastComponent
        if last.isEmpty { return servers.server(favorite.location.serverID)?.displayName ?? "Server" }
        return last
    }

    /// The volume or server it lives on.
    private var badge: String? {
        switch favorite.location {
        case .local(let url): return sidebar.volumeName(for: url)
        case .remote(let id, _): return servers.server(id)?.displayName
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

private struct StatusDot: View {
    let state: ConnectionState

    var body: some View {
        switch state {
        case .connected:
            Circle().fill(.primary).frame(width: 6, height: 6).help("Connected")
        case .connecting:
            ProgressView().controlSize(.mini).help("Connecting…")
        case .failed(let why):
            Image(systemName: "exclamationmark.circle").foregroundStyle(Color.failure).font(.caption).help(why)
        case .idle:
            EmptyView()
        }
    }
}

extension Color {
    /// Muted red, used only for failures (PRD Visual language).
    static let failure = Color(red: 0xB3 / 255, green: 0x5C / 255, blue: 0x5C / 255)
}
