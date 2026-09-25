// Finder-style path bar under the file list (PRD R2.15): the path of the
// selected item (or the current folder), from its volume or server down.
// Click a folder to go there; drop items on one to move or copy them into it.

import BlitSFTP
import SwiftUI

struct PathSegment: Identifiable {
    let location: BrowseLocation
    let name: String
    let icon: NSImage
    let isFolder: Bool
    var id: BrowseLocation { location }
}

struct PathBar: View {
    let browser: BrowserModel

    var body: some View {
        let segments = self.segments
        HStack(spacing: 3) {
            ForEach(Array(segments.enumerated()), id: \.element.id) { index, segment in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                PathSegmentView(segment: segment, browser: browser)
                    // The item itself keeps its name longest; ancestors shrink first.
                    .layoutPriority(index == segments.count - 1 ? 2 : index == 0 ? 1 : 0)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 8)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    /// The selected item if exactly one is selected, else the current folder,
    /// with every folder above it up to the volume or server.
    private var segments: [PathSegment] {
        guard let current = browser.current else { return [] }
        let selected = browser.selection.count == 1 ? browser.selectedItems.first : nil
        var chain: [(BrowseLocation, Bool)] = []
        var next: BrowseLocation? = selected?.location ?? current
        var isFolder = selected?.isDirectory ?? true
        while let location = next {
            chain.append((location, isFolder))
            isFolder = true
            next = location.parent
        }
        // Drives and shares start at their volume, not at / › Volumes.
        if let url = current.localURL, url.pathComponents.count >= 3, url.pathComponents[1] == "Volumes" {
            chain.removeAll { $0.0.localURL.map { $0.path == "/" || $0.path == "/Volumes" } ?? false }
        }
        return chain.reversed().map { location, isFolder in
            PathSegment(location: location, name: name(of: location), icon: icon(of: location, isFolder: isFolder),
                        isFolder: isFolder)
        }
    }

    private func name(of location: BrowseLocation) -> String {
        switch location {
        case .local(let url):
            let isVolume = url.path == "/" || url.deletingLastPathComponent().path == "/Volumes"
            if isVolume, let name = (try? url.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName {
                return name
            }
            return url.lastPathComponent
        case .remote(let id, let bytes):
            if bytes.isEmpty || bytes == [UInt8(ascii: "/")] {
                return browser.servers.server(id)?.displayName ?? "Server"
            }
            return location.lastComponent
        }
    }

    private func icon(of location: BrowseLocation, isFolder: Bool) -> NSImage {
        switch location {
        case .local(let url):
            return IconCache.shared.icon(forPath: url.path)
        case .remote(_, let bytes):
            if bytes.isEmpty || bytes == [UInt8(ascii: "/")] {
                return NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil) ?? NSImage()
            }
            return IconCache.shared.icon(for: FileItem(location: location, name: location.lastComponent,
                                                       isDirectory: isFolder, modified: .distantPast, size: 0, kind: ""))
        }
    }
}

private struct PathSegmentView: View {
    let segment: PathSegment
    let browser: BrowserModel
    @State private var isHovered = false
    @State private var isTargeted = false

    var body: some View {
        Button {
            if segment.isFolder { browser.open(segment.location) }
        } label: {
            HStack(spacing: 3) {
                Image(nsImage: segment.icon)
                    .resizable()
                    .frame(width: 14, height: 14)
                Text(segment.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.primary.opacity(isTargeted ? 0.15 : (isHovered && segment.isFolder ? 0.08 : 0)))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(segment.isFolder ? .secondary : .primary)
        .onHover { isHovered = $0 }
        .help(segment.isFolder ? "Go to “\(segment.name)”" : segment.name)
        .dropDestination(for: TransferPayload.self) { payloads, _ in
            guard segment.isFolder else { return false }
            let sources = payloads.flatMap(\.locations).uniqued().filter { $0 != segment.location }
            guard !sources.isEmpty else { return false }
            browser.drop(sources, into: segment.location, name: segment.name)
            return true
        } isTargeted: { isTargeted = $0 && segment.isFolder }
    }
}
