// Back Up Edits (PRD R2.26): a shoot's edit files (DxO PhotoLab's .dop, XMP)
// copied to the NAS next to their photos once the user says the shoot is done.
// Only edit files that are missing there or older there go; never photos,
// never a delete. The NAS side of a shoot is the folder with the same name in
// one of the camera folders under the NAS photos folder (chosen once):
// Photographs/Digital/Sony_a7Riii/2026-10-13_Boston for 2026-10-13_Boston.

import Foundation

/// Where the photo features keep their settings: the user's defaults, or a
/// test copy's own scratch suite.
@MainActor
enum PhotoSettings {
    static var store: UserDefaults {
        TransferManager.isIsolated ? UserDefaults(suiteName: "com.banastas.blit.test-photos") ?? .standard : .standard
    }

    /// The NAS folder that holds the camera folders (Photographs/Digital).
    static var nasPhotos: URL? {
        get { store.string(forKey: "photosNASFolder").map { URL(fileURLWithPath: $0, isDirectory: true) } }
        set { store.set(newValue?.path, forKey: "photosNASFolder") }
    }

    #if DEBUG
    static func resetTestStore() {
        guard TransferManager.isIsolated else { return }
        store.removePersistentDomain(forName: "com.banastas.blit.test-photos")
    }
    #endif
}

/// One shoot's edits, checked against the NAS.
struct EditBackupShoot: Identifiable, Sendable {
    /// Edit files bound for one NAS folder (a shoot shot on two cameras has two).
    struct Target: Sendable {
        let nasFolder: URL
        let camera: String
        let edits: [URL]
    }

    let folder: URL
    var targets: [Target] = []
    /// Edit files already as they are here.
    var upToDate = 0
    /// Edit files whose photo isn't on the NAS (they're left out).
    var withoutPhoto = 0
    /// Why the shoot can't be backed up ("not on the NAS"), if it can't.
    var problem: String?

    var id: String { folder.path }
    var name: String { folder.lastPathComponent }
    var toBackUp: Int { targets.reduce(0) { $0 + $1.edits.count } }
}

enum EditBackup {
    /// DxO PhotoLab's sidecars ("_DSC0398.ARW.dop") and XMP ("_DSC0398.xmp").
    static let editExtensions: Set<String> = ["dop", "xmp"]

    /// A shoot folder's name: a date first ("2026-10-20", "2026-10-13_Boston").
    static func isShootName(_ name: String) -> Bool {
        name.wholeMatch(of: /\d{4}-\d{2}-\d{2}([ _-].*)?/) != nil
    }

    /// Checks each folder's edit files against the NAS: which are missing or
    /// older there. Reads the disks, so call it off the main thread.
    /// `checked` is told how many shoots are done.
    static func plan(_ folders: [URL], nas: URL, checked: @Sendable (Int) -> Void = { _ in }) -> [EditBackupShoot] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let cameras = ((try? fm.contentsOfDirectory(at: nas, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        struct Entry { let size: Int; let modified: Date }
        func listing(_ folder: URL) -> [String: Entry]? {
            guard let urls = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return nil }
            var entries: [String: Entry] = [:]
            for url in urls {
                guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isDirectory != true else { continue }
                entries[url.lastPathComponent] = Entry(size: values.fileSize ?? -1, modified: values.contentModificationDate ?? .distantPast)
            }
            return entries
        }
        var shoots: [EditBackupShoot] = []
        for (index, folder) in folders.enumerated() {
            defer { checked(index + 1) }
            var shoot = EditBackupShoot(folder: folder)
            guard let here = listing(folder) else {
                shoot.problem = "Can't read this folder."
                shoots.append(shoot)
                continue
            }
            let edits = here.keys.filter { editExtensions.contains(($0 as NSString).pathExtension.lowercased()) }.sorted()
            guard !edits.isEmpty else {
                shoot.problem = "No edit files (.dop, .xmp) here."
                shoots.append(shoot)
                continue
            }
            // The same-named folder in each camera folder.
            let there: [(camera: String, folder: URL, files: [String: Entry])] = cameras.compactMap { camera in
                let candidate = camera.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
                guard let files = listing(candidate) else { return nil }
                return (camera.lastPathComponent, candidate, files)
            }
            guard !there.isEmpty else {
                shoot.problem = "Not on the NAS: no “\(folder.lastPathComponent)” in a camera folder in “\(nas.lastPathComponent)”."
                shoots.append(shoot)
                continue
            }
            var byFolder: [URL: [URL]] = [:]
            for name in edits {
                // The photo it belongs to: "X.ARW" for "X.ARW.dop"; for "X.xmp", any "X.*".
                let ext = (name as NSString).pathExtension.lowercased()
                let stem = (name as NSString).deletingPathExtension
                let home = there.first { side in
                    ext == "dop" ? side.files[stem] != nil
                        : side.files.keys.contains { ($0 as NSString).deletingPathExtension == stem && !editExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
                }
                guard let home else { shoot.withoutPhoto += 1; continue }
                let local = here[name]!
                if let copy = home.files[name], copy.size == local.size, local.modified.timeIntervalSince(copy.modified) <= 2 {
                    shoot.upToDate += 1
                } else {
                    byFolder[home.folder, default: []].append(folder.appendingPathComponent(name))
                }
            }
            shoot.targets = there.compactMap { side in
                byFolder[side.folder].map { EditBackupShoot.Target(nasFolder: side.folder, camera: side.camera, edits: $0) }
            }
            shoots.append(shoot)
        }
        return shoots
    }

    /// Queues a verified copy of each shoot's edits to its NAS folder,
    /// replacing the older ones there. Returns a problem, if any.
    @MainActor static func start(_ shoots: [EditBackupShoot], transfers: TransferManager) -> String? {
        var problems: [String] = []
        for shoot in shoots {
            for target in shoot.targets where !target.edits.isEmpty {
                if let problem = transfers.enqueue(target.edits.map { .local($0) }, to: .local(target.nasFolder),
                                                   destinationName: "\(target.camera)/\(shoot.name)", existsRule: .replace,
                                                   title: "Edits · \(shoot.name)") {
                    problems.append(problem)
                }
            }
        }
        return problems.first
    }

    /// The shoot folders a request covers: the selected ones; else this folder
    /// if it's a shoot; else every shoot folder in it (the catch-up).
    @MainActor static func folders(selected: [FileItem], in browser: BrowserModel) -> [URL] {
        let chosen = selected.filter { $0.isDirectory && isShootName($0.name) }.compactMap(\.location.localURL)
        if !chosen.isEmpty { return chosen }
        if let here = browser.current?.localURL, isShootName(here.lastPathComponent) { return [here] }
        return browser.items.filter { $0.isDirectory && isShootName($0.name) }.compactMap(\.location.localURL)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
