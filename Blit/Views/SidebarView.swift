// Standard macOS sidebar: Favorites (drag folders in, reorder, ⌘D), Drives,
// and NAS shares (PRD R2.9).

import SwiftUI

struct SidebarView: View {
    @Environment(SidebarModel.self) private var sidebar
    @Binding var selection: URL?

    var body: some View {
        List(selection: $selection) {
            Section("Favorites") {
                ForEach(sidebar.favorites) { favorite in
                    let available = sidebar.isAvailable(favorite)
                    HStack {
                        Label(favorite.name, systemImage: available ? "folder" : "folder.badge.questionmark")
                        Spacer(minLength: 4)
                        if let volume = sidebar.volumeName(for: favorite.url) {
                            Text(volume)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    .foregroundStyle(available ? .primary : .tertiary)
                    .help(available ? favorite.url.path : "\(favorite.url.path) isn't available")
                    .tag(favorite.url)
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([favorite.url]) }
                            .disabled(!available)
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

            Section("Drives") {
                ForEach(sidebar.drives) { drive in
                    Label(drive.name, systemImage: drive.isInternal ? "internaldrive" : "externaldrive")
                        .tag(drive.url)
                }
            }

            if !sidebar.networkShares.isEmpty {
                Section("NAS") {
                    ForEach(sidebar.networkShares) { share in
                        Label(share.name, systemImage: "server.rack")
                            .tag(share.url)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}
