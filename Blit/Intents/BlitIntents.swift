// "Copy with Blit" (PRD R6.1): an App Intent for Shortcuts, Spotlight and
// Finder Quick Actions. Files go to a Blit favorite, drive or NAS share with
// the same verified copy as a drag and drop.

import AppIntents
import Foundation

struct DestinationEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Blit Destination"
    static let defaultQuery = DestinationQuery()

    /// The folder's path (destinations are local folders, drives or NAS mounts).
    let id: String
    let name: String
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)")
    }

    var location: BrowseLocation { .local(URL(fileURLWithPath: id)) }
}

struct DestinationQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [DestinationEntity] {
        Self.all().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [DestinationEntity] { Self.all() }

    /// Local favorites first, then mounted NAS shares and external drives.
    static func all() -> [DestinationEntity] {
        var result: [DestinationEntity] = []
        var seen = Set<String>()
        func add(_ url: URL, _ name: String, _ detail: String) {
            let path = url.standardizedFileURL.path
            guard seen.insert(path).inserted, FileManager.default.fileExists(atPath: path) else { return }
            result.append(DestinationEntity(id: path, name: name, detail: detail))
        }
        if let data = UserDefaults.standard.data(forKey: "favorites"),
           let favorites = try? JSONDecoder().decode([Favorite].self, from: data) {
            for favorite in favorites {
                if let url = favorite.location.localURL { add(url, url.lastPathComponent, (url.path as NSString).abbreviatingWithTildeInPath) }
            }
        }
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsLocalKey, .volumeIsInternalKey]
        for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? [] {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), url.path != "/" else { continue }
            let name = v.volumeLocalizedName ?? url.lastPathComponent
            if v.volumeIsLocal == false { add(url, name, "NAS share") } else if v.volumeIsInternal != true { add(url, name, "Drive") }
        }
        return result
    }
}

struct CopyWithBlitIntent: AppIntent {
    static let title: LocalizedStringResource = "Copy with Blit"
    static let description = IntentDescription("Copies files to a Blit favorite, drive or NAS share, verifying every file.")
    static let openAppWhenRun = true

    @Parameter(title: "Files", supportedContentTypes: [.item])
    var files: [IntentFile]

    @Parameter(title: "Destination")
    var destination: DestinationEntity

    @Dependency private var transfers: TransferManager

    static var parameterSummary: some ParameterSummary {
        Summary("Copy \(\.$files) to \(\.$destination) with Blit")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let urls = files.compactMap(\.fileURL)
        guard !urls.isEmpty else {
            throw BlitIntentError.message("These items aren't files Blit can read.")
        }
        if let problem = transfers.enqueue(urls.map { .local($0) }, to: destination.location, destinationName: destination.name) {
            throw BlitIntentError.message(problem)
        }
        let what = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items"
        return .result(dialog: "Copying \(what) to \(destination.name). Blit verifies every file.")
    }
}

enum BlitIntentError: Error, CustomLocalizedStringResourceConvertible {
    case message(String)

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .message(let text): "\(text)"
        }
    }
}

struct BlitShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CopyWithBlitIntent(),
                    phrases: ["Copy with \(.applicationName)", "Send files with \(.applicationName)"],
                    shortTitle: "Copy with Blit",
                    systemImageName: "arrow.down.doc")
    }
}
