// Row icons (PRD R2.16): Quick Look thumbnails for local files (images,
// videos, PDFs… on drives and NAS shares), generated lazily for visible rows
// and cached; type icons otherwise. Files on servers use type icons, since a
// thumbnail would mean downloading the file.

import AppKit
import QuickLookThumbnailing
import SwiftUI

struct FileIcon: View {
    let item: FileItem
    @AppStorage("showIconPreviews") private var showPreviews = true
    @State private var thumbnail: NSImage?

    var body: some View {
        Image(nsImage: thumbnail ?? IconCache.shared.icon(for: item))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 16, height: 16)
            .task(id: TaskKey(location: item.location, modified: item.modified, enabled: showPreviews)) {
                thumbnail = nil
                guard showPreviews, !item.isDirectory, let url = item.location.localURL else { return }
                thumbnail = await ThumbnailCache.shared.thumbnail(for: url, modified: item.modified)
            }
    }

    private struct TaskKey: Equatable {
        let location: BrowseLocation
        let modified: Date
        let enabled: Bool
    }
}

@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()
    /// Files Quick Look had no thumbnail for (MKV, text…), so they aren't asked again.
    private var none = Set<String>()

    init() { cache.countLimit = 2000 }

    func thumbnail(for url: URL, modified: Date) async -> NSImage? {
        let key = "\(url.path)|\(modified.timeIntervalSinceReferenceDate)"
        if let image = cache.object(forKey: key as NSString) { return image }
        guard !none.contains(key) else { return nil }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 16, height: 16),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                   representationTypes: [.lowQualityThumbnail, .thumbnail])
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            if !Task.isCancelled { none.insert(key) }
            return nil
        }
        let image = representation.nsImage
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}
