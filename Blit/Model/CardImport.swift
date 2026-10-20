// Card import (PRD R5.12): a camera card's photos copied to this Mac, a folder
// per shoot day ("2026-10-20", or "2026-10-13_Boston" with a place), then that
// folder backed up to the NAS folder for the camera, each copy verified.
// Offered when a card (a volume with a DCIM folder) goes in; nothing copies
// until the user says so, photos already imported are skipped, and the card
// is never changed or erased.

import AppKit
import ImageIO
import UserNotifications

/// One photo on a card.
struct CardPhoto: Sendable {
    let url: URL
    let size: Int64
    /// The day it was taken ("2026-10-20"), from its EXIF (else its file date).
    let day: String
    /// Make, model and serial ("SONY ILCE-7RM3 4123456"): which NAS folder.
    let cameraKey: String
    /// Model, for display ("ILCE-7RM3").
    let camera: String
    var name: String { url.lastPathComponent }
}

/// A day's photos on a card.
struct CardDay: Identifiable, Sendable {
    let day: String
    var photos: [CardPhoto]
    var id: String { day }
    var bytes: Int64 { photos.reduce(0) { $0 + $1.size } }
    /// The camera most of the day's photos came from.
    var cameraKey: String { Self.mostCommon(photos.map(\.cameraKey)) }
    var camera: String { photos.first { $0.cameraKey == cameraKey }?.camera ?? "" }

    private static func mostCommon(_ keys: [String]) -> String {
        Dictionary(keys.map { ($0, 1) }, uniquingKeysWith: +).max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key ?? ""
    }
}

enum CardImport {
    /// Still photos: camera raw formats, JPEG, HEIF, TIFF, PNG. (Video isn't imported.)
    static let photoExtensions: Set<String> = ["arw", "cr2", "cr3", "nef", "nrw", "raf", "orf", "rw2", "dng", "pef", "srw",
                                               "3fr", "iiq", "x3f", "jpg", "jpeg", "heic", "heif", "hif", "tif", "tiff", "png"]

    /// A camera card: a volume with a DCIM folder at its root.
    nonisolated static func isCard(_ volume: URL) -> Bool {
        var directory: ObjCBool = false
        return FileManager.default.fileExists(atPath: volume.appendingPathComponent("DCIM").path, isDirectory: &directory) && directory.boolValue
    }

    /// The card's photos (in DCIM), without reading them.
    nonisolated static func photoFiles(on card: URL) -> [URL] {
        let dcim = card.appendingPathComponent("DCIM")
        guard let walk = FileManager.default.enumerator(at: dcim, includingPropertiesForKeys: [.isRegularFileKey],
                                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var files: [URL] = []
        for case let url as URL in walk where photoExtensions.contains(url.pathExtension.lowercased()) { files.append(url) }
        return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The card's photos by day, oldest first, from each photo's EXIF (its
    /// headers only). Reads the card: call it off the main thread.
    nonisolated static func scan(_ card: URL, read: @Sendable (Int, Int) -> Void = { _, _ in }) -> [CardDay] {
        let files = photoFiles(on: card)
        var byDay: [String: [CardPhoto]] = [:]
        let dayFormat = DateFormatter()
        dayFormat.locale = Locale(identifier: "en_US_POSIX")
        dayFormat.dateFormat = "yyyy-MM-dd"
        for (index, url) in files.enumerated() {
            if index % 20 == 0 { read(index, files.count) }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let info = exif(url)
            let day = info.day ?? dayFormat.string(from: values?.contentModificationDate ?? Date())
            let photo = CardPhoto(url: url, size: Int64(values?.fileSize ?? 0), day: day,
                                  cameraKey: info.cameraKey, camera: info.camera)
            byDay[day, default: []].append(photo)
        }
        read(files.count, files.count)
        return byDay.keys.sorted().map { CardDay(day: $0, photos: byDay[$0]!) }
    }

    /// The day a photo was taken, and its camera, from its EXIF.
    nonisolated static func exif(_ url: URL) -> (day: String?, cameraKey: String, camera: String) {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] else { return (nil, "", "") }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        // "2026:10:20 14:03:22" → "2026-10-20"
        let taken = (exif[kCGImagePropertyExifDateTimeOriginal] ?? tiff[kCGImagePropertyTIFFDateTime]) as? String
        let day = taken.flatMap { text -> String? in
            let date = text.prefix(10).replacingOccurrences(of: ":", with: "-")
            return date.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil ? date : nil
        }
        let make = (tiff[kCGImagePropertyTIFFMake] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let model = (tiff[kCGImagePropertyTIFFModel] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let serial = (exif[kCGImagePropertyExifBodySerialNumber] as? String ?? "").trimmingCharacters(in: .whitespaces)
        let key = [make, model, serial].filter { !$0.isEmpty }.joined(separator: " ")
        return (day, key, model.isEmpty ? make : model)
    }

    /// "2026-10-20", or "2026-10-20_Boston" with a place ("St Louis" → "_St-Louis").
    static func folderName(day: String, place: String) -> String {
        let words = place.split(whereSeparator: { $0.isWhitespace || $0 == "/" || $0 == ":" }).joined(separator: "-")
        let trimmed = words.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
        return trimmed.isEmpty ? day : "\(day)_\(trimmed)"
    }

    /// A folder for `day` already in `root` ("2026-10-20" or "2026-10-20_Boston"),
    /// and the place in its name. Reads the disk.
    nonisolated static func existingFolder(for day: String, in root: URL) -> (url: URL, place: String)? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        guard let name = names.filter({ $0 == day || $0.hasPrefix(day + "_") }).sorted().first else { return nil }
        return (root.appendingPathComponent(name, isDirectory: true), name == day ? "" : String(name.dropFirst(day.count + 1)))
    }

    /// The photos already in `folder` (same name and size). Reads the disk.
    nonisolated static func alreadyImported(_ photos: [CardPhoto], in folder: URL) -> Set<String> {
        var there: Set<String> = []
        for photo in photos {
            let size = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(photo.name).path))?[.size] as? Int64
            if size == photo.size { there.insert(photo.name) }
        }
        return there
    }

    /// One day to import: its new photos, the folder they go in, and the NAS
    /// camera folder its backup goes in (nil: no backup).
    struct Plan: Sendable {
        let day: String
        let folderName: String
        let photos: [CardPhoto]
        let nasCamera: URL?
    }

    /// Queues each day: its new photos card → this Mac, then that folder's
    /// new photos → the NAS camera folder, both verified. Returns a problem.
    @MainActor static func start(_ plans: [Plan], to root: URL, transfers: TransferManager) -> String? {
        let fm = FileManager.default
        var problems: [String] = []
        for plan in plans where !plan.photos.isEmpty {
            let folder = root.appendingPathComponent(plan.folderName, isDirectory: true)
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                problems.append("Couldn't make “\(plan.folderName)”: \(error.localizedDescription)")
                continue
            }
            if let problem = transfers.enqueue(plan.photos.map { .local($0.url) }, to: .local(folder), destinationName: plan.folderName,
                                               existsRule: .keepBoth, title: "Import · \(plan.folderName)") {
                problems.append(problem)
                continue
            }
            guard let camera = plan.nasCamera else { continue }
            // From this Mac's verified copies (the card can go once those are done).
            let backup = camera.appendingPathComponent(plan.folderName, isDirectory: true)
            do {
                try fm.createDirectory(at: backup, withIntermediateDirectories: true)
            } catch {
                problems.append("Couldn't make “\(plan.folderName)” on the NAS: \(error.localizedDescription)")
                continue
            }
            if let problem = transfers.enqueue(plan.photos.map { .local(folder.appendingPathComponent($0.name)) }, to: .local(backup),
                                               destinationName: "\(camera.lastPathComponent)/\(plan.folderName)",
                                               existsRule: .keepBoth, title: "Backup · \(plan.folderName)") {
                problems.append(problem)
            }
        }
        return problems.first
    }
}

extension PhotoSettings {
    /// Where imported shoots go on this Mac (the SSD).
    static var importDestination: URL? {
        get { store.string(forKey: "photosImportFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { store.set(newValue?.path, forKey: "photosImportFolder") }
    }

    /// The NAS camera folder for a camera (by make, model and serial).
    static func nasFolder(forCamera key: String) -> URL? {
        (store.dictionary(forKey: "photosCameraFolders")?[key] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static func setNASFolder(_ url: URL?, forCamera key: String) {
        var folders = store.dictionary(forKey: "photosCameraFolders") ?? [:]
        folders[key] = url?.path
        store.set(folders, forKey: "photosCameraFolders")
    }
}

/// Camera cards as they come and go: the import sheet is offered when one goes
/// in (in the active pane; with a notification when Blit isn't in front).
@MainActor
@Observable
final class CardWatcher {
    static let shared = CardWatcher()
    /// Mounted cards.
    private(set) var cards: [URL] = []
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
            let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { if let volume { CardWatcher.shared.mounted(volume) } }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { note in
            let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated {
                guard let volume else { return }
                CardWatcher.shared.cards.removeAll { $0.standardizedFileURL == volume.standardizedFileURL }
            }
        })
        // Cards in already: listed (for File › Import Card…), not offered.
        Task {
            let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
            let found = await Task.detached { volumes.filter(CardImport.isCard) }.value
            for card in found where !cards.contains(card) { cards.append(card) }
        }
    }

    private func mounted(_ volume: URL) {
        Task {
            guard await Task.detached(operation: { CardImport.isCard(volume) }).value else { return }
            if !cards.contains(volume) { cards.append(volume) }
            offer(volume)
        }
    }

    /// Shows the import sheet for `card` in the active pane, and a
    /// notification when Blit isn't in front.
    func offer(_ card: URL) {
        if let pane = BrowserModel.active, pane.cardImport == nil { pane.cardImport = card }
        guard !NSApp.isActive, !TransferManager.isIsolated else { return }   // a test copy never notifies
        let count = CardImport.photoFiles(on: card).count
        let content = UNMutableNotificationContent()
        content.title = "Import photos from “\(card.lastPathComponent)”?"
        content.body = count == 1 ? "1 photo on the card. Click to choose where it goes." : "\(count) photos on the card. Click to choose where they go."
        content.userInfo = ["card": card.path]
        Task { try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "card-\(card.path)", content: content, trigger: nil)) }
    }
}
