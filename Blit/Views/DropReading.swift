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

    /// Everything on a drag pasteboard, read at once (the AppKit list's
    /// drops): Blit's own payload where an item has it, else a file URL.
    static func locations(on pasteboard: NSPasteboard) -> [BrowseLocation] {
        let blit = NSPasteboard.PasteboardType(UTType.blitLocations.identifier)
        var found: [BrowseLocation] = []
        for item in pasteboard.pasteboardItems ?? [] {
            if let data = item.data(forType: blit), let payload = try? JSONDecoder().decode(TransferPayload.self, from: data) {
                found += payload.locations
            } else if let string = item.string(forType: .fileURL), let url = URL(string: string) {
                found.append(.local(url))
            }
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

    /// Replaces what SwiftUI put on the drag pasteboard for a drag that's
    /// starting with Blit's payload alone: no file promise, which other apps
    /// would accept (Finder wrote the payload out as a file) and which nobody
    /// fulfils. SwiftUI writes the pasteboard just after asking for the
    /// providers, so this waits for its promise to appear (up to 1 s).
    static func keepOnlyPayload(_ data: Data) {
        let ours = NSPasteboard.PasteboardType(UTType.blitLocations.identifier)
        let promise = NSPasteboard.PasteboardType("com.apple.NSFilePromiseItemMetaData")
        // The pasteboard still holds the last drag until SwiftUI writes this one.
        let before = NSPasteboard(name: .drag).changeCount
        func attempt(_ tries: Int) {
            let board = NSPasteboard(name: .drag)
            let types = board.types ?? []
            if board.changeCount != before, types.contains(ours), types.contains(promise) {
                board.clearContents()
                board.setData(data, forType: ours)
                #if DEBUG
                UITestHarness.dropTrail.append("payload only (was \(types.count) types)")
                #endif
            } else if tries > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { attempt(tries - 1) }
            }
        }
        DispatchQueue.main.async { attempt(50) }
    }

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


/// What a drag over a drop target would do (a folder row lighting up, the
/// list's outline, a sidebar row or the line between two), shown only while
/// the drag is over it. Its own object, read only by the marks that draw it:
/// kept as state of the view with the drop handler, every change rebuilt that
/// handler mid-drag, and a quick drop let go just then was lost and left the
/// drag stuck (the window took no clicks until force quit).
@MainActor
@Observable
final class DragHover<Value: Equatable> {
    private(set) var value: Value?
    /// The drop just made, told apart from the next drag by the drag
    /// pasteboard (every drag writes it anew): macOS sends one more "drag
    /// moved" 310–370 ms after a drop, which lit the mark again after it was
    /// cleared, and nothing cleared it (a stuck outline or insertion line).
    /// The next drag can arrive with no "entered" at all, so time or entry
    /// alone can't tell them apart.
    @ObservationIgnored private var drop: (time: Date, pasteboard: Int)?
    /// Safety net: a drop target means something only while a button is held.
    @ObservationIgnored private var watchdog: Timer?
    @ObservationIgnored private var idleChecks = 0

    init() {
        #if DEBUG
        DragHoverRegistry.add(self)
        #endif
    }

    /// A drag came in.
    func entered(_ value: Value) {
        drop = nil
        show(value)
    }

    /// It moved over the target (ignored if it's the drag that just dropped).
    func moved(_ value: Value) {
        if let drop {
            guard NSPasteboard(name: .drag).changeCount != drop.pasteboard else {
                #if DEBUG
                UITestHarness.dropTrail.append("late update ignored +\(Int(Date().timeIntervalSince(drop.time) * 1000)) ms")
                #endif
                return
            }
            self.drop = nil   // a new drag
        }
        show(value)
    }

    func exited() { clear() }

    func dropped() {
        drop = (Date(), NSPasteboard(name: .drag).changeCount)
        clear()
    }

    private func show(_ new: Value) {
        if value != new { value = new }
        startWatchdog()
    }

    private func clear() {
        if value != nil { value = nil }
        watchdog?.invalidate()
        watchdog = nil
    }

    /// Clears the mark if no mouse button has been down for half a second.
    private func startWatchdog() {
        idleChecks = 0
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.idleChecks = NSEvent.pressedMouseButtons == 0 ? self.idleChecks + 1 : 0
                if self.idleChecks >= 2 {
                    #if DEBUG
                    UITestHarness.dropTrail.append("highlight cleared: no button down")
                    #endif
                    self.clear()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }
}

#if DEBUG
extension DragHover: DragHoverShowing {
    var isShowing: Bool { value != nil }
}

@MainActor
protocol DragHoverShowing: AnyObject {
    var isShowing: Bool { get }
}

/// Every drop target's hover, for the drag tests ("is anything still lit?").
@MainActor
enum DragHoverRegistry {
    private static let all = NSHashTable<AnyObject>.weakObjects()
    static func add(_ hover: AnyObject) { all.add(hover) }
    static var anyShowing: Bool { all.allObjects.contains { ($0 as? any DragHoverShowing)?.isShowing == true } }
}
#endif

/// Where a drop on a file list would go: the list's own folder, or a folder row.
enum ListDrop: Equatable {
    case list
    case folder(BrowseLocation)
}
