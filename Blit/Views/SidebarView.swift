// Standard macOS sidebar: Favorites (drag folders in, reorder, ⌘D), Servers,
// Drives and NAS shares (PRD R2.9).

import BlitSFTP
import SwiftUI

struct SidebarView: View {
    @Environment(SidebarModel.self) private var sidebar
    @Environment(ServerStore.self) private var servers
    @Environment(ConnectionManager.self) private var connections
    @Binding var selection: BrowseLocation?
    var onAddServer: () -> Void
    var onEditServer: (ServerConfig) -> Void
    var onRemoveServer: (ServerConfig) -> Void

    var body: some View {
        List(selection: $selection) {
            Section("Favorites") {
                ForEach(sidebar.favorites) { favorite in
                    FavoriteRow(favorite: favorite)
                        .tag(favorite.location)
                        .contextMenu {
                            if let url = favorite.location.localURL {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                    .disabled(!sidebar.isAvailable(favorite))
                            }
                            Button("Remove from Favorites") { sidebar.removeFavorite(favorite) }
                        }
                }
                .onMove { sidebar.moveFavorites(from: $0, to: $1) }
                .dropDestination(for: URL.self) { urls, index in
                    sidebar.addFavorites(urls, at: index)
                }
                if sidebar.favorites.isEmpty {
                    Text("Drag folders here")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .selectionDisabled()
                }
            }

            Section {
                ForEach(servers.servers) { server in
                    HStack {
                        Label(server.displayName, systemImage: "server.rack")
                        Spacer(minLength: 4)
                        StatusDot(state: connections.state(server))
                    }
                    .tag(server.startLocation)
                    .contextMenu {
                        Button("Edit…") { onEditServer(server) }
                        Button("Disconnect") { connections.disconnect(server) }
                            .disabled(connections.state(server) != .connected)
                        Divider()
                        Button("Remove…", role: .destructive) { onRemoveServer(server) }
                    }
                }
                if servers.servers.isEmpty {
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
                        .tag(BrowseLocation.local(drive.url))
                }
            }

            if !sidebar.networkShares.isEmpty {
                Section("NAS") {
                    ForEach(sidebar.networkShares) { share in
                        Label(share.name, systemImage: "externaldrive.connected.to.line.below")
                            .tag(BrowseLocation.local(share.url))
                    }
                }
            }
        }
        .listStyle(.sidebar)
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
