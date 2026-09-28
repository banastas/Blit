// Sidebar locations: pinned favorites (PRD R2.9) and mounted volumes, split
// into local drives and network (NAS) shares. Volumes update as they mount.

import AppKit
import BlitLocal
import Network
import Observation
import UniformTypeIdentifiers

struct Favorite: Codable, Identifiable, Hashable {
    var id = UUID()
    var location: BrowseLocation

    init(location: BrowseLocation) { self.location = location }

    enum CodingKeys: String, CodingKey { case id, location, url }

    // Favorites saved before server support stored a plain `url`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        if let location = try c.decodeIfPresent(BrowseLocation.self, forKey: .location) {
            self.location = location
        } else {
            self.location = .local(try c.decode(URL.self, forKey: .url))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(location, forKey: .location)
    }
}

struct VolumeLocation: Identifiable, Hashable {
    var url: URL
    var name: String
    var isInternal: Bool
    /// For network shares: the device serving it ("d1ll1N9eR"), from the mount.
    var host: String?
    var id: URL { url }
}

/// A device on the network and the shares mounted from it.
struct NetworkDevice: Identifiable, Hashable {
    var name: String
    /// Bonjour _device-info model ("Xserve" for a Synology NAS, "Macmini9,1"…), if advertised.
    var model: String?
    var shares: [VolumeLocation]
    var id: String { name }

    var symbol: String {
        guard let model else { return "desktopcomputer" }
        if model.hasPrefix("Xserve") || model.contains("RackMac") { return "server.rack" }
        if model.hasPrefix("Macmini") { return "macmini" }
        if model.hasPrefix("MacBook") { return "laptopcomputer" }
        if model.hasPrefix("MacPro") { return "macpro.gen3" }
        if model.hasPrefix("Mac1") || model.hasPrefix("MacStudio") { return "macstudio" }
        return "desktopcomputer"
    }
}

@MainActor
@Observable
final class SidebarModel {
    private(set) var favorites: [Favorite] = []
    private(set) var drives: [VolumeLocation] = []
    private(set) var networkShares: [VolumeLocation] = []
    /// Network shares grouped by the device serving them.
    private(set) var networkDevices: [NetworkDevice] = []
    @ObservationIgnored private var models: [String: String] = [:]
    @ObservationIgnored private var modelBrowser: NWBrowser?

    private static let favoritesKey = "favorites"
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    init() {
        loadFavorites()
        // The launch scan is synchronous so the startup selection (first
        // available favorite, first external drive) sees the volumes; later
        // refreshes run off the main thread.
        let (local, network) = Self.scanVolumes()
        apply(local: local, network: network, scan: volumeScan)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVolumes() }
            })
        }
    }

    // MARK: Volumes

    /// Serial of the newest scan, so an older one finishing late can't
    /// overwrite a newer result.
    @ObservationIgnored private var volumeScan = 0

    func refreshVolumes() {
        // Volume metadata queries can hang for the SMB timeout on a share
        // that's dropping off the network — exactly when the unmount
        // notification fires — so the scan runs off the main thread and only
        // its results land on it.
        volumeScan += 1
        let scan = volumeScan
        Task.detached(priority: .userInitiated) { [weak self] in
            let (local, network) = SidebarModel.scanVolumes()
            await self?.apply(local: local, network: network, scan: scan)
        }
    }

    private nonisolated static func scanVolumes() -> (local: [VolumeLocation], network: [VolumeLocation]) {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsLocalKey, .volumeIsInternalKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        var local: [VolumeLocation] = []
        var network: [VolumeLocation] = []
        for url in urls {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.volumeIsBrowsable != false else { continue }
            var location = VolumeLocation(url: url, name: v.volumeLocalizedName ?? url.lastPathComponent,
                                          isInternal: v.volumeIsInternal ?? false)
            if v.volumeIsLocal == false {
                location.host = deviceName(forMount: url.path)
                network.append(location)
            } else {
                local.append(location)
            }
        }
        return (local, network)
    }

    private func apply(local: [VolumeLocation], network: [VolumeLocation], scan: Int) {
        guard scan == volumeScan else { return }
        // Boot volume first, then alphabetical.
        drives = local.sorted { ($0.url.path == "/" ? 0 : 1, $0.name) < ($1.url.path == "/" ? 0 : 1, $1.name) }
        networkShares = network.sorted { $0.name < $1.name }
        VolumeKinds.networkRoots = Set(networkShares.map { $0.url.standardizedFileURL.path })
        // Remember how each share was mounted, to reconnect it later (PRD R1.5).
        for share in networkShares { ShareMounter.remember(mountPoint: share.url.standardizedFileURL.path) }
        regroupDevices()
        if modelBrowser == nil, !networkShares.isEmpty { browseDeviceModels() }
    }

    private func regroupDevices() {
        let groups = Dictionary(grouping: networkShares) { $0.host ?? $0.name }
        networkDevices = groups.map { NetworkDevice(name: $0.key, model: models[$0.key.lowercased()], shares: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "//user@d1ll1N9eR._smb._tcp.local/Media" → "d1ll1N9eR"; "//user@192.168.20.111/Media" → "192.168.20.111".
    nonisolated static func deviceName(forMount path: String) -> String? {
        // The mount table, not statfs: a hung share would block statfs for
        // the whole SMB timeout.
        guard let source = MountInfo.mounted(at: path)?.source,
              let host = source.split(separator: "@").last?.split(separator: "/").first else { return nil }
        var name = String(host).removingPercentEncoding ?? String(host)
        for suffix in ["._smb._tcp.local", "._smb._tcp", "._afpovertcp._tcp.local", ".local"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
        }
        return name
    }

    /// Learns device models from Bonjour (_device-info._tcp) for sidebar icons.
    private func browseDeviceModels() {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_device-info._tcp", domain: "local."), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            var found: [String: String] = [:]
            for result in results {
                guard case .service(let name, _, _, _) = result.endpoint,
                      case .bonjour(let txt) = result.metadata, let model = txt["model"] else { continue }
                found[name.lowercased()] = model
            }
            Task { @MainActor in
                guard let self else { return }
                self.models.merge(found) { _, new in new }
                self.regroupDevices()
            }
        }
        browser.start(queue: .main)
        modelBrowser = browser
    }

    /// The volume a URL lives on, for the favorite's badge ("Media", "SSD").
    func volumeName(for url: URL) -> String? {
        let all = drives + networkShares
        let match = all.filter { url.path == $0.url.path || url.path.hasPrefix($0.url.path == "/" ? "/" : $0.url.path + "/") }
            .max { $0.url.path.count < $1.url.path.count }
        return match?.name
    }

    // MARK: Favorites

    /// Local favorites need their folder present; server favorites are checked when opened.
    /// Whether a favorite's volume is mounted. Answered from the mounted-volume
    /// lists, not the file system: this runs on every sidebar render, and a
    /// file check on a dead SMB share would freeze the app.
    func isAvailable(_ favorite: Favorite) -> Bool {
        guard let url = favorite.location.localURL else { return true }
        let parts = url.standardizedFileURL.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return true }   // on the startup disk
        let volume = "/Volumes/" + parts[2]
        return (drives + networkShares).contains { $0.url.standardizedFileURL.path == volume }
    }

    /// Adds folders (ignoring files and duplicates) at `index`, or at the end.
    func addFavorites(_ urls: [URL], at index: Int? = nil) {
        let folders = urls.map(\.standardizedFileURL).filter { url in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
                && !isFavorite(.local(url))
        }
        guard !folders.isEmpty else { return }
        let insertAt = min(index ?? favorites.count, favorites.count)
        favorites.insert(contentsOf: folders.map { Favorite(location: .local($0)) }, at: insertAt)
        saveFavorites()
    }

    /// Adds favorites from a drop onto the Favorites section: Finder folder URLs
    /// or Blit's own drag payload (local or server folders).
    func addDropped(_ providers: [NSItemProvider], at index: Int? = nil) {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.blitLocations.identifier) {
                _ = provider.loadDataRepresentation(for: .blitLocations) { data, _ in
                    guard let data, let payload = try? JSONDecoder().decode(TransferPayload.self, from: data) else { return }
                    Task { @MainActor in
                        for location in payload.folders ?? [] { self.addFavorite(location, at: index) }
                    }
                }
            } else if provider.canLoadObject(ofClass: URL.self) {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in self.addFavorites([url], at: index) }
                }
            }
        }
    }

    /// Adds any location (a local folder or a folder on a server), e.g. from ⌘D.
    func addFavorite(_ location: BrowseLocation, at index: Int? = nil) {
        if case .local(let url) = location { return addFavorites([url], at: index) }
        guard !isFavorite(location) else { return }
        favorites.insert(Favorite(location: location), at: min(index ?? favorites.count, favorites.count))
        saveFavorites()
    }

    /// Removes favorites on a server that's been deleted.
    func removeFavorites(onServer id: UUID) {
        favorites.removeAll { $0.location.serverID == id }
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

    func isFavorite(_ location: BrowseLocation) -> Bool {
        favorites.contains { favorite in
            if let a = favorite.location.localURL, let b = location.localURL {
                return a.standardizedFileURL == b.standardizedFileURL
            }
            return favorite.location == location
        }
    }

    private func loadFavorites() {
        // Test copies keep their own Favorites in memory (a drop there must never
        // land in one of the user's real folders).
        guard !TransferManager.isIsolated else { return }
        guard let data = UserDefaults.standard.data(forKey: Self.favoritesKey),
              let saved = try? JSONDecoder().decode([Favorite].self, from: data) else { return }
        favorites = saved
    }

    private func saveFavorites() {
        guard !TransferManager.isIsolated else { return }
        if let data = try? JSONEncoder().encode(favorites) {
            UserDefaults.standard.set(data, forKey: Self.favoritesKey)
        }
    }
}

/// Which mounted volumes are network shares, from the sidebar's last volume
/// scan. Menus and drops ask this instead of the file system, which blocks
/// for the SMB timeout when a share has dropped off the network.
@MainActor
enum VolumeKinds {
    static var networkRoots: Set<String> = []

    /// True for a path on a network share (SMB), false for local volumes.
    static func isNetwork(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return networkRoots.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
