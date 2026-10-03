// Row icons (PRD R2.16): Quick Look thumbnails for local files (images,
// videos, PDFs… on drives and NAS shares), generated lazily for visible rows
// and cached; type icons otherwise. Files on servers use type icons, since a
// thumbnail would mean downloading the file.

import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

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
            if !Task.isCancelled {
                if none.count > 5000 { none.removeAll() }
                none.insert(key)
            }
            return nil
        }
        let image = representation.nsImage
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}

/// File icons by type, cached (per-file icons are slow over SMB).
@MainActor
final class IconCache {
    static let shared = IconCache()
    private var cache: [String: NSImage] = [:]
    private var pathCache: [String: NSImage] = [:]

    /// Finder's icon for a folder or volume (drive icons, shared-folder badges).
    func icon(forPath path: String) -> NSImage {
        if let cached = pathCache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        pathCache[path] = image
        return image
    }

    func icon(for item: FileItem) -> NSImage {
        let key = item.isDirectory ? "/folder" : (item.name as NSString).pathExtension.lowercased()
        if let cached = cache[key] { return cached }
        let type = item.isDirectory ? UTType.folder : (UTType(filenameExtension: key) ?? .data)
        let image = NSWorkspace.shared.icon(for: type)
        cache[key] = image
        return image
    }

    private var rowCache: [String: NSImage] = [:]

    /// The same icon drawn once at a row's 16 pt (and 32 px). Handed to an
    /// image view, the full icon went to Core Animation at its largest size,
    /// 1024 px: 4 MB for each kind of file in view.
    func rowIcon(for item: FileItem) -> NSImage {
        let key = item.isDirectory ? "/folder" : (item.name as NSString).pathExtension.lowercased()
        if let cached = rowCache[key] { return cached }
        let source = icon(for: item)
        let image = NSImage(size: NSSize(width: 16, height: 16))
        for scale in [1, 2] {
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16 * scale, pixelsHigh: 16 * scale,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
            rep.size = NSSize(width: 16, height: 16)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            source.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
            NSGraphicsContext.restoreGraphicsState()
            image.addRepresentation(rep)
        }
        rowCache[key] = image
        return image
    }
}
