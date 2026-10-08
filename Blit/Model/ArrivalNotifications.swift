// What a download's notification adds when it lands (PRD R5.5): a still from
// the video (about a fifth of the way in, past dark frames, so it's a real
// scene and not a black lead-in or a studio card), and Quick Look and Rename,
// which bring Blit forward with the item selected in the active pane: review
// starts from the notification.

import AppKit
import AVFoundation
import UniformTypeIdentifiers
import UserNotifications

@MainActor
enum ArrivalNotifications {
    static let category = "transfer-arrival"
    static let severalCategory = "transfer-arrival-several"
    /// The same, with a missing episode named (MissingEpisodes).
    static let gapCategory = "transfer-arrival-gap"
    static let severalGapCategory = "transfer-arrival-several-gap"
    static let quickLookAction = "quick-look"
    static let renameAction = "rename"
    static let ignoreGapsAction = "ignore-gaps"

    /// The categories (with Show in Finder, as every finished transfer has).
    static func categories(reveal: UNNotificationAction) -> [UNNotificationCategory] {
        let quickLook = UNNotificationAction(identifier: quickLookAction, title: "Quick Look", options: [.foreground])
        let rename = UNNotificationAction(identifier: renameAction, title: "Rename", options: [.foreground])
        let ignore = UNNotificationAction(identifier: ignoreGapsAction, title: "Ignore Gaps in This Show", options: [])
        return [UNNotificationCategory(identifier: category, actions: [quickLook, rename, reveal], intentIdentifiers: []),
                UNNotificationCategory(identifier: severalCategory, actions: [quickLook, reveal], intentIdentifiers: []),
                UNNotificationCategory(identifier: gapCategory, actions: [quickLook, rename, reveal, ignore], intentIdentifiers: []),
                UNNotificationCategory(identifier: severalGapCategory, actions: [quickLook, reveal, ignore], intentIdentifiers: [])]
    }

    /// Turns a finished download's notification into an arrival: the still,
    /// the actions, and what they act on.
    static func decorate(_ content: UNMutableNotificationContent, for job: TransferJob, transfers: TransferManager?) async {
        guard content.categoryIdentifier == TransferNotifications.doneCategory, job.lane == .download else { return }
        let items = landed(job)
        guard !items.isEmpty else { return }
        let video = await Task.detached { mainVideo(in: items) }.value
        content.categoryIdentifier = items.count == 1 ? category : severalCategory
        var info = content.userInfo
        info["items"] = items.map(\.path)
        // Quick Look shows the video itself, inside its pack.
        info["preview"] = (video ?? items[0]).path
        content.userInfo = info
        // A hole in the season it leaves, said only when Blit is sure.
        if let gap = await MissingEpisodes.note(for: job, transfers: transfers) {
            content.body += "\n" + gap.text
            content.categoryIdentifier = items.count == 1 ? gapCategory : severalGapCategory
            content.userInfo["gapShows"] = gap.shows
        }
        if let video, let still = await poster(for: video),
           let attachment = try? UNNotificationAttachment(identifier: "still", url: still, options: nil) {
            content.attachments = [attachment]
        }
    }

    /// The items the job put in its destination that are there now.
    static func landed(_ job: TransferJob) -> [URL] {
        job.sources.map { job.destination.appendingPathComponent($0.lastComponent) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    nonisolated static let videoExtensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "mts", "wmv", "mpg", "mpeg"]

    /// The largest video among `items` (a file, or inside a folder a level or
    /// two down): the feature, not its sample.
    nonisolated static func mainVideo(in items: [URL]) -> URL? {
        var best: (url: URL, size: Int64)?
        func consider(_ url: URL) {
            guard videoExtensions.contains(url.pathExtension.lowercased()),
                  let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return }
            if Int64(size) > best?.size ?? -1 { best = (url, Int64(size)) }
        }
        for item in items {
            var isFolder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &isFolder) else { continue }
            guard isFolder.boolValue else { consider(item); continue }
            let walker = FileManager.default.enumerator(at: item, includingPropertiesForKeys: [.fileSizeKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants])
            while let url = walker?.nextObject() as? URL {
                if walker?.level ?? 0 > 2 { walker?.skipDescendants(); continue }
                consider(url)
            }
        }
        return best?.url
    }

    /// A still from `video` as a JPEG in the temporary folder (the
    /// notification takes it from there): a fifth of the way in, or further
    /// in where that's dark; the brightest tried if all are.
    nonisolated static func poster(for video: URL) async -> URL? {
        let asset = AVURLAsset(url: video)
        guard let duration = try? await asset.load(.duration), duration.seconds.isFinite, duration.seconds > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 960, height: 540)
        // The nearest keyframe is fine, and much faster.
        let tolerance = CMTime(seconds: min(10, duration.seconds / 20), preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        var brightest: (image: CGImage, light: Double)?
        for fraction in [0.2, 0.35, 0.5, 0.65] {
            let time = CMTime(seconds: duration.seconds * fraction, preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else { continue }
            let light = brightness(image)
            if light > brightest?.light ?? -1 { brightest = (image, light) }
            if light >= 0.12 { break }
        }
        guard let image = brightest?.image else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("blit-still-\(UUID().uuidString).jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? url : nil
    }

    /// How light `image` is on average, 0 (black) to 1 (white).
    nonisolated static func brightness(_ image: CGImage) -> Double {
        let width = 32, height = 18
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return 0 }
        var total = 0.0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            total += 0.2126 * Double(pixels[index]) + 0.7152 * Double(pixels[index + 1]) + 0.0722 * Double(pixels[index + 2])
        }
        return total / Double(width * height) / 255
    }

    // MARK: Acting on one

    /// Quick Look, Rename, or a click on the notification: Blit, the active
    /// pane at the item's folder with the item selected, then a preview or
    /// its name ready to edit.
    static func act(_ action: String, items: [String], preview: String?) async {
        guard let first = items.first else { return }
        let target = URL(fileURLWithPath: action == quickLookAction ? (preview ?? first) : first)
        for _ in 0..<40 where BrowserModel.active == nil { try? await Task.sleep(for: .milliseconds(100)) }
        guard let pane = BrowserModel.active else { return }
        let folder = BrowseLocation.local(target.deletingLastPathComponent())
        if pane.current?.localURL?.lexicalPath != target.deletingLastPathComponent().lexicalPath { pane.open(folder) }
        var row: FileItem?
        for _ in 0..<50 {
            row = pane.rows.first { $0.depth == 0 && $0.name == target.lastPathComponent }
            if row != nil { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let row else { return }
        pane.selection = [row.id]
        pane.requestKeyboardFocus()
        switch action {
        case quickLookAction: pane.previewSelection()
        case renameAction: pane.beginRename(row)
        default: break
        }
    }
}
