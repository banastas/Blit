// The Video column (PRD R2.6): each local video file's header, read in the
// background as its row is shown, two at a time and the latest request first
// (the rows on screen after a scroll), and kept for the session by path, size
// and modification date. Reads that land within a moment go out together, so
// the lists refresh once for a screenful rather than once a file.

import BlitMedia
import Foundation
import Observation

@MainActor
@Observable
final class VideoDetails {
    static let shared = VideoDetails()

    private struct Entry: Equatable {
        let size: Int64
        let modified: Date
        let info: VideoInfo?
    }

    private struct Request {
        let key: String
        let url: URL
        let size: Int64
        let modified: Date
    }

    /// What's been read, by path. Observed: the lists' marks watch it.
    private var known: [String: Entry] = [:]
    @ObservationIgnored private var waiting: [Request] = []
    @ObservationIgnored private var queued: Set<String> = []
    @ObservationIgnored private var reading = 0
    @ObservationIgnored private var landed: [String: Entry] = [:]
    @ObservationIgnored private var publishing = false
    /// Paths in the order they were read, to drop the oldest past `keptLimit`.
    @ObservationIgnored private var order: [String] = []

    private static let concurrent = 2, waitingLimit = 300, keptLimit = 20_000

    /// Whether the column has anything to say about `item`: a local file of a
    /// kind Blit reads (servers' files would need a download to look inside).
    static func handles(_ item: FileItem) -> Bool {
        !item.isDirectory && item.location.localURL.map(VideoProbe.handles) == true
    }

    /// `item`'s details once they've been read (for its size and date now);
    /// until then nil, and a read is queued.
    func info(for item: FileItem) -> VideoInfo? {
        guard Self.handles(item), let url = item.location.localURL else { return nil }
        let key = url.lexicalPath
        if let entry = known[key], entry.size == item.size, entry.modified == item.modified { return entry.info }
        if !queued.contains(key) {
            queued.insert(key)
            waiting.append(Request(key: key, url: url, size: item.size, modified: item.modified))
            if waiting.count > Self.waitingLimit { queued.remove(waiting.removeFirst().key) }
            readNext()
        }
        return nil
    }

    private func readNext() {
        while reading < Self.concurrent, let request = waiting.popLast() {
            reading += 1
            Task.detached(priority: .utility) {
                let info = await VideoProbe.probe(request.url)
                await VideoDetails.shared.land(request, info)
            }
        }
    }

    private func land(_ request: Request, _ info: VideoInfo?) {
        reading -= 1
        queued.remove(request.key)
        landed[request.key] = Entry(size: request.size, modified: request.modified, info: info)
        readNext()
        guard !publishing else { return }
        publishing = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            publish()
        }
    }

    private func publish() {
        publishing = false
        guard !landed.isEmpty else { return }
        var known = self.known
        for (key, entry) in landed {
            if known.updateValue(entry, forKey: key) == nil { order.append(key) }
        }
        landed = [:]
        if order.count > Self.keptLimit {
            let drop = order.prefix(order.count - Self.keptLimit / 2)
            for key in drop { known[key] = nil }
            order.removeFirst(drop.count)
        }
        self.known = known
    }

    #if DEBUG
    /// Forgets what's been read (the tests start clean).
    func reset() {
        known = [:]
        order = []
    }

    /// Reads waiting or under way, for the tests.
    var busy: Bool { reading > 0 || !waiting.isEmpty || !landed.isEmpty }
    #endif
}
