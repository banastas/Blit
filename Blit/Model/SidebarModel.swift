// Sidebar locations: pinned favorites (PRD R2.9) and mounted volumes, split
// into local drives and network (NAS) shares. Volumes update as they mount.

import AppKit
import Observation

struct Favorite: Codable, Identifiable, Hashable {
    var id = UUID()
    var url: URL
    var name: String { url.lastPathComponent }
}

struct VolumeLocation: Identifiable, Hashable {
    var url: URL
    var name: String
    var isInternal: Bool
    var id: URL { url }
}

@MainActor
@Observable
final class SidebarModel {
    private(set) var favorites: [Favorite] = []
    private(set) var drives: [VolumeLocation] = []
    private(set) var networkShares: [VolumeLocation] = []

    private static let favoritesKey = "favorites"
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        loadFavorites()
        refreshVolumes()
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            })
        }
    }

    // MARK: Volumes

    func refreshVolumes() {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var local: [VolumeLocation] = []
        var network: [VolumeLocation] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false else { continue }
            let location = VolumeLocation(url: url, name: v.volumeLocalizedName ?? url.lastPathComponent,
                                          isInternal: v.volumeIsInternal ?? false)
            if v.volumeIsLocal == false { network.append(location) } else { local.append(location) }
        }
        // Boot volume first, then alphabetical.
        drives = local.sorted { ($0.url.path == "/" ? 0 : 1, $0.name) < ($1.url.path == "/" ? 0 : 1, $1.name) }
        networkShares = network.sorted { $0.name < $1.name }
    }

    /// The volume a URL lives on, for the favorite's badge ("Media", "SSD").
    func volumeName(for url: URL) -> String? {
        let all = drives + networkShares
        let match = all.filter { url.path == $0.url.path || url.path.hasPrefix($0.url.path == "/" ? "/" : $0.url.path + "/") }
            .max { $0.url.path.count < $1.url.path.count }
        return match?.name
    }

    // MARK: Favorites

    func isAvailable(_ favorite: Favorite) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: favorite.url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Adds folders (ignoring files and duplicates) at `index`, or at the end.
    func addFavorites(_ urls: [URL], at index: Int? = nil) {
        let folders = urls.filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                && !favorites.contains { $0.url.standardizedFileURL == url.standardizedFileURL }
        }
        guard !folders.isEmpty else { return }
        let insertAt = min(index ?? favorites.count, favorites.count)
        favorites.insert(contentsOf: folders.map { Favorite(url: $0.standardizedFileURL) }, at: insertAt)
        saveFavorites()
    }

    func removeFavorite(_ favorite: Favorite) {
        favorites.removeAll { $0.id == favorite.id }
        saveFavorites()
    }

    func moveFavorites(from source: IndexSet, to destination: Int) {
        favorites.move(fromOffsets: source, toOffset: destination)
        saveFavorites()
    }

    func isFavorite(_ url: URL) -> Bool {
        favorites.contains { $0.url.standardizedFileURL == url.standardizedFileURL }
    }

    private func loadFavorites() {
        guard let data = UserDefaults.standard.data(forKey: Self.favoritesKey),
              let saved = try? JSONDecoder().decode([Favorite].self, from: data) else { return }
        favorites = saved
    }

    private func saveFavorites() {
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: Self.favoritesKey)
        }
    }
}
