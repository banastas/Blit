// Reading what was dropped, and knowing what's being dragged while it's in
// the air (to offer "add to Favorites" only for folders).

import AppKit
import UniformTypeIdentifiers

@MainActor
enum DropReader {
    /// Everything dragged, read from all the items at once. A multi-row drag
    /// makes one item per row, each carrying the whole selection, and some of
    /// them never answer a read: waiting on them one by one hung the drop. So
    /// every read starts together, and whatever has arrived when they've all
    /// answered, or after 3 s, is used.
    static func locations(from providers: [NSItemProvider]) async -> [BrowseLocation] {
        guard !providers.isEmpty else { return [] }
        let found = await withCheckedContinuation { (continuation: CheckedContinuation<[BrowseLocation], Never>) in
            let gather = DropGather(expected: providers.count, continuation: continuation)
            for provider in providers { read(provider) { gather.add($0) } }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { gather.finish() }
        }
        return found.uniqued()
    }

    /// Reads one dragged item: Blit's own payload, or a file URL from Finder.
    private static func read(_ provider: NSItemProvider, _ done: @escaping @Sendable ([BrowseLocation]) -> Void) {
        if provider.hasItemConformingToTypeIdentifier(UTType.blitLocations.identifier) {
            _ = provider.loadDataRepresentation(for: .blitLocations) { data, _ in
                let payload = data.flatMap { try? JSONDecoder().decode(TransferPayload.self, from: $0) }
                done(payload?.locations ?? [])
            }
        } else if provider.canLoadObject(ofClass: URL.self) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in done(url.map { [.local($0)] } ?? []) }
        } else {
            done([])
        }
    }
}

/// Collects the reads of a drop's items; answers once, when all have come in
/// or at the timeout.
private final class DropGather: @unchecked Sendable {
    private let lock = NSLock()
    private var locations: [BrowseLocation] = []
    private var answers = 0
    private let expected: Int
    private var continuation: CheckedContinuation<[BrowseLocation], Never>?

    init(expected: Int, continuation: CheckedContinuation<[BrowseLocation], Never>) {
        self.expected = expected
        self.continuation = continuation
    }

    func add(_ found: [BrowseLocation]) {
        lock.lock()
        locations += found
        answers += 1
        let complete = answers >= expected
        lock.unlock()
        if complete { finish() }
    }

    func finish() {
        lock.lock()
        let pending = continuation
        continuation = nil
        let result = locations
        lock.unlock()
        pending?.resume(returning: result)
    }
}

/// What the drag in progress carries, known while it's in the air (a drop's
/// items can only be read once it lands).
@MainActor
enum DragContents {
    private static var fromList: TransferPayload?

    /// A drag from a Blit file list began with `payload`.
    static func started(_ payload: TransferPayload) { fromList = payload }

    /// Whether the drag in progress holds a folder: from a Blit list, what it
    /// began with; from Finder, the file URLs on the drag pasteboard.
    static var hasFolders: Bool {
        let board = NSPasteboard(name: .drag)
        if board.types?.contains(NSPasteboard.PasteboardType(UTType.blitLocations.identifier)) == true {
            return !(fromList?.folders ?? []).isEmpty
        }
        let urls = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.contains { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
    }
}
