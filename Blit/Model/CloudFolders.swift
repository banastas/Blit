// iCloud Drive and the folders File Provider apps keep in sync (Proton Drive,
// Dropbox, Google Drive, OneDrive…), listed with the drives (PRD R2.2). To
// Blit they're local folders on the startup disk; the provider uploads what
// lands in them and downloads what's read from them.

import Foundation

enum CloudFolders {
    /// iCloud Drive's own folder (Finder's iCloud Drive; apps' folders live beside it).
    static let iCloudDrive = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")

    /// Where File Provider apps keep their folders.
    static let providers = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")

    /// The cloud folders present, iCloud Drive first. Only names are read, never
    /// a provider's contents (that asks macOS for permission, and can wait on
    /// the provider).
    static func scan() -> [VolumeLocation] {
        var found: [VolumeLocation] = []
        let fm = FileManager.default
        if fm.fileExists(atPath: iCloudDrive.path) {
            found.append(VolumeLocation(url: iCloudDrive, name: "iCloud Drive", isInternal: true, isCloud: true))
        }
        let folders = (try? fm.contentsOfDirectory(at: providers, includingPropertiesForKeys: [.isDirectoryKey],
                                                   options: [.skipsHiddenFiles])) ?? []
        var others: [VolumeLocation] = []
        for url in folders where (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let (name, account) = displayName(folder: url.lastPathComponent)
            others.append(VolumeLocation(url: url, name: name, isInternal: true, host: account, isCloud: true))
        }
        // Two accounts with one provider: tell them apart by the account.
        let counts = Dictionary(grouping: others, by: \.name).mapValues(\.count)
        others = others.map { folder in
            guard counts[folder.name, default: 0] > 1, let account = folder.host else { return folder }
            var named = folder
            named.name = "\(folder.name) (\(account))"
            return named
        }
        return found + others.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "ProtonDrive-me@example.com-folder" → ("Proton Drive", "me@example.com"),
    /// "GoogleDrive-me@gmail.com" → ("Google Drive", …), "OneDrive-Personal",
    /// "Dropbox". A provider's folder is "<Provider>-<account>[-folder]";
    /// macOS gives no display name for it outside Finder.
    static func displayName(folder: String) -> (name: String, account: String?) {
        var parts = folder.components(separatedBy: "-")
        let provider = parts.removeFirst()
        if parts.last == "folder" { parts.removeLast() }
        let account = parts.isEmpty ? nil : parts.joined(separator: "-")
        let known = ["ProtonDrive": "Proton Drive", "GoogleDrive": "Google Drive", "OneDrive": "OneDrive",
                     "Dropbox": "Dropbox", "Box": "Box", "SynologyDrive": "Synology Drive", "pCloudDrive": "pCloud Drive"]
        if let name = known[provider] { return (name, account) }
        // Otherwise split the CamelCase: "MegaSync" → "Mega Sync".
        var name = ""
        for (index, character) in provider.enumerated() {
            if index > 0, character.isUppercase, let previous = name.last, previous.isLowercase { name.append(" ") }
            name.append(character)
        }
        return (name.isEmpty ? folder : name, account)
    }

    /// The cloud folders found at the last scan, for names and badges.
    @MainActor static var roots: [VolumeLocation] = []

    /// The cloud folder `url` is in (or is), if any.
    @MainActor static func folder(containing url: URL) -> VolumeLocation? {
        let path = url.standardizedFileURL.path
        return roots.first { path == $0.url.path || path.hasPrefix($0.url.path + "/") }
    }

    /// Whether the file at `path` is only in the cloud (not downloaded yet): a
    /// clone of it would copy the placeholder, and a rename out of the
    /// provider's folder can fail, so Blit copies it (reading downloads it).
    static func isDataless(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0 else { return false }
        return info.st_flags & 0x4000_0000 != 0   // SF_DATALESS
    }
}
