// Torrent status in server panes (PRD R2.25): for each item in a folder that
// qBittorrent saves into, what qBittorrent is doing with it, read from its
// records (TorrentLibrary): downloading (how far, live from its files on
// disk, and about how long is left), stalled (no data for how long), queued
// or stopped, or seeding (for how long, at what ratio, against any share
// limit). Only for folders shown on screen: records again every minute, a
// download's files every 20 seconds while Blit is in front (a minute when it
// isn't), nothing while the window is hidden.

import AppKit
import Foundation

@MainActor
@Observable
final class TorrentStatusBoard {
    static let shared = TorrentStatusBoard()

    /// Each claimed item's status, by its location in the folder shown.
    private(set) var statuses: [BrowseLocation: FileStatus] = [:]

    @ObservationIgnored private var loop: Task<Void, Never>?
    /// Per folder shown: its torrents and when they were last read.
    @ObservationIgnored private var folders: [BrowseLocation: (torrents: [TorrentEntry], settings: TorrentSettings, read: Date)] = [:]
    @ObservationIgnored private var lastLive: [BrowseLocation: Date] = [:]
    /// Per torrent: recent samples of its bytes on disk, and the latest.
    @ObservationIgnored private var samples: [String: [(time: Date, bytes: Int64)]] = [:]
    @ObservationIgnored private var live: [String: TorrentLiveBytes] = [:]
    @ObservationIgnored private var ticking = false
    @ObservationIgnored private var ticks = 0
    /// How often records and live bytes are read (a test shortens them).
    @ObservationIgnored var recordsInterval: TimeInterval = 60
    @ObservationIgnored var liveInterval: TimeInterval = 20
    @ObservationIgnored var liveIntervalInBackground: TimeInterval = 60
    /// The least time between samples for a rate, and whether a hidden window stops it all.
    @ObservationIgnored var rateSpan: TimeInterval = 15
    @ObservationIgnored var requiresVisibleWindow = true

    func status(for item: FileItem) -> FileStatus? {
        item.depth == 0 ? statuses[item.location] : nil
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    /// One pass over the folders on screen.
    func tick() async {
        guard !ticking else { return }
        ticks += 1
        ticking = true
        defer { ticking = false }
        let visible = !requiresVisibleWindow || (BrowserModel.activeWindow.map { $0.isVisible && $0.occlusionState.contains(.visible) } ?? false)
        let shown = visible ? Set(Panes.shared.shownLocations.filter(Self.isEligible)) : []
        for gone in folders.keys where !shown.contains(gone) {
            folders[gone] = nil
            lastLive[gone] = nil
        }
        // Side by side: a slow server doesn't hold up the others.
        await withTaskGroup(of: Void.self) { group in
            for folder in shown { group.addTask { await self.refresh(folder) } }
        }
        var next: [BrowseLocation: FileStatus] = [:]
        for folder in shown {
            guard let read = folders[folder] else { continue }
            let now = Date()
            for torrent in read.torrents {
                let status = Self.status(of: torrent, live: live[torrent.id], rate: rate(torrent.id, now: now),
                                         settings: read.settings, now: now)
                for name in torrent.placed {
                    let location = FileOperations.child(of: folder, named: name)
                    // Two torrents in one folder: a download says more than a seed.
                    if let existing = next[location], existing.glyph == "▼" || existing.isWarning { continue }
                    next[location] = status
                }
            }
        }
        if next != statuses { statuses = next }
    }

    private func refresh(_ folder: BrowseLocation) async {
        guard let library = TorrentLibrary.shared else { return }
        let now = Date()
        if now.timeIntervalSince(folders[folder]?.read ?? .distantPast) >= recordsInterval {
            guard let records = await library.recordsFolder(for: folder), let path = await library.absolutePath(folder),
                  let torrents = await library.torrents(in: records, on: folder) else {
                folders[folder] = ([], TorrentSettings(), now)
                return
            }
            let settings = await library.settings(for: folder, records: records)?.settings ?? TorrentSettings()
            folders[folder] = (torrents.filter { Self.samePath($0.resume.savePath, path) }, settings, now)
        }
        guard let read = folders[folder], !read.settings.preallocates else { return }
        let downloading = read.torrents.filter { !$0.resume.finished }
        guard !downloading.isEmpty else { return }
        let interval = NSApp.isActive ? liveInterval : liveIntervalInBackground
        guard now.timeIntervalSince(lastLive[folder] ?? .distantPast) >= interval,
              let path = await library.absolutePath(folder) else { return }
        lastLive[folder] = now
        // Each torrent's names in the folder, measured together.
        let paths = downloading.flatMap { torrent in torrent.placed.sorted().map { (torrent.id, path + "/" + $0) } }
        guard let measured = await library.liveBytes(paths.map(\.1), on: folder) else { return }
        var totals: [String: TorrentLiveBytes] = [:]
        for ((id, _), bytes) in zip(paths, measured) {
            var total = totals[id] ?? TorrentLiveBytes(bytes: 0, newestWrite: nil)
            total.bytes = total.bytes.addingReportingOverflow(bytes.bytes).overflow ? .max : total.bytes + bytes.bytes
            total.newestWrite = [total.newestWrite, bytes.newestWrite].compactMap { $0 }.max()
            totals[id] = total
        }
        let taken = Date()
        for (id, total) in totals {
            live[id] = total
            var list = (samples[id] ?? []).filter { taken.timeIntervalSince($0.time) < 300 }
            list.append((taken, total.bytes))
            samples[id] = Array(list.suffix(8))
        }
    }

    /// Bytes a second over the recent samples, if they show progress.
    private func rate(_ id: String, now: Date) -> Double? {
        guard let list = samples[id], let first = list.first, let last = list.last,
              last.time.timeIntervalSince(first.time) >= rateSpan, last.bytes > first.bytes else { return nil }
        return Double(last.bytes - first.bytes) / last.time.timeIntervalSince(first.time)
    }

    nonisolated static func samePath(_ a: String, _ b: String) -> Bool {
        func trimmed(_ path: String) -> String { path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path }
        return trimmed(a) == trimmed(b)
    }

    /// Folders on a server (or, in a test copy, its stand-in records' folder).
    static func isEligible(_ folder: BrowseLocation) -> Bool {
        switch folder {
        case .remote:
            #if DEBUG
            // A test copy leaves the user's servers alone unless a test asks.
            return !TransferManager.isIsolated || UserDefaults.standard.bool(forKey: "BlitTorrentStatusRemote")
            #else
            return true
            #endif
        case .local:
            #if DEBUG
            return TransferManager.isIsolated && UserDefaults.standard.string(forKey: "BlitWatchRecordsHome") != nil
            #else
            return false
            #endif
        }
    }

    // MARK: What a status says

    /// Gone this long without new data, a download counts as stalled.
    nonisolated static let stallAfter: TimeInterval = 15 * 60

    nonisolated static func status(of torrent: TorrentEntry, live: TorrentLiveBytes?, rate: Double?,
                                   settings: TorrentSettings, now: Date) -> FileStatus {
        let resume = torrent.resume
        let size = max(torrent.size, 1)
        // Files that take their full size on disk before they're done
        // (preallocated, or a file system that fills small holes) say nothing
        // about progress: the records' figure stands then.
        let live = live.flatMap { $0.bytes >= size && resume.fraction < 0.98 ? nil : $0 }
        if resume.finished {
            // Seeding time keeps counting between the records' hourly rewrites.
            let since = resume.stopped ? 0 : max(0, now.timeIntervalSince(torrent.recorded ?? now))
            let seeded = resume.seedingTime + since
            let ratio = Self.ratio(resume, size: torrent.size)
            let ratioLimit = resume.ratioLimit ?? settings.ratioLimit
            let minutesLimit = resume.seedingMinutesLimit ?? settings.seedingMinutesLimit
            var text = (resume.stopped ? "stopped · seeded " : "seeding ") + duration(seeded)
            if minutesLimit >= 0 { text += " of " + duration(TimeInterval(minutesLimit * 60)) }
            text += " · " + ratioText(ratio)
            if ratioLimit >= 0 { text += " of " + ratioText(ratioLimit) }
            var help = "qBittorrent: " + (resume.stopped ? "finished and stopped" : "seeding") + " for " + duration(seeded, long: true)
            help += ". Uploaded " + bytes(resume.uploaded) + ", ratio " + String(format: "%.2f", ratio) + "."
            let limits = [minutesLimit >= 0 ? "seeding for " + duration(TimeInterval(minutesLimit * 60), long: true) : nil,
                          ratioLimit >= 0 ? "a ratio of " + String(format: "%.2f", ratioLimit) : nil].compactMap { $0 }
            help += limits.isEmpty ? " No share limit is set in qBittorrent." : " qBittorrent's share limit: " + limits.joined(separator: " or ") + "."
            return FileStatus(text: text, glyph: resume.stopped ? "‖" : "▲", help: help)
        }
        // How far: the files on disk now, else the records (up to an hour old).
        let fraction = max(resume.fraction, live.map { min(1, Double($0.bytes) / Double(size)) } ?? 0)
        let percent = Int((fraction * 100).rounded(.down))
        let source = live == nil ? "as of qBittorrent's last record" : "from its files on the server"
        if resume.stopped {
            return FileStatus(text: "stopped · \(percent)%", glyph: "‖", help: "qBittorrent: stopped at \(percent)% (\(source)).")
        }
        if resume.queued {
            return FileStatus(text: "queued · \(percent)%", glyph: nil, help: "qBittorrent: waiting in its queue, \(percent)% done (\(source)).")
        }
        // Last data: a file written on the server, else the records' own note.
        let lastData = [live?.newestWrite, resume.lastDownload].compactMap { $0 }.max()
        let quiet = lastData.map { now.timeIntervalSince($0) } ?? .infinity
        // The records are rewritten about hourly, so without the files to go
        // by, a download is only called stalled once its note is well past that.
        let stalled = live != nil ? quiet >= stallAfter : quiet >= 2 * 3600
        if stalled {
            let text = lastData.map { "stalled · " + duration(now.timeIntervalSince($0)) } ?? "stalled · no data yet"
            let help = "qBittorrent hasn't received anything for this " + (lastData.map { "in " + duration(now.timeIntervalSince($0), long: true) } ?? "yet")
                + "; it's \(percent)% done (\(source))."
            return FileStatus(text: text, glyph: nil, help: help, isWarning: true)
        }
        var text = "\(percent)%"
        var help = "qBittorrent is downloading this: \(percent)% (\(source))"
        if let rate, rate > 0, live != nil {
            let left = Double(size) * (1 - fraction) / rate
            text += " · " + duration(left)
            help += ", " + (left < 60 ? "" : "about ") + duration(left, long: true) + " left at " + bytes(Int64(rate)) + "/s"
        }
        return FileStatus(text: text, glyph: "▼", help: help + ".")
    }

    /// qBittorrent's own: uploaded over downloaded, or over the size when it
    /// downloaded almost nothing itself (added already complete).
    nonisolated static func ratio(_ resume: TorrentResume, size: Int64) -> Double {
        let downloaded = Double(resume.downloaded) < Double(size) * 0.01 ? Double(size) : Double(resume.downloaded)
        guard downloaded > 0 else { return 0 }
        return Double(resume.uploaded) / downloaded
    }

    nonisolated static func ratioText(_ ratio: Double) -> String {
        ratio >= 10 ? String(format: "%.0f×", ratio) : String(format: "%.1f×", ratio)
    }

    /// "45 min", "3 h", "6 d" (or in words, for help).
    nonisolated static func duration(_ seconds: TimeInterval, long: Bool = false) -> String {
        let minutes = Int((seconds / 60).rounded())
        func unit(_ value: Int, _ short: String, _ word: String) -> String {
            long ? "\(value) \(word)\(value == 1 ? "" : "s")" : "\(value) \(short)"
        }
        if minutes < 1 { return long ? "less than a minute" : "<1 min" }
        if minutes < 60 { return unit(minutes, "min", "minute") }
        let hours = Int((seconds / 3600).rounded())
        if hours < 48 { return unit(hours, "h", "hour") }
        return unit(Int((seconds / 86_400).rounded()), "d", "day")
    }

    nonisolated static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    #if DEBUG
    var isTicking: Bool { ticking }

    /// What it holds (a test reads it).
    var describe: String {
        "ticks \(ticks) · ticking \(ticking) · folders " + folders.map { "\($0.key.lastComponent): \($0.value.torrents.count) torrents \($0.value.torrents.map { $0.placed.sorted().joined(separator: "+") })" }.joined(separator: "; ")
            + " · live \(live.count) · statuses \(statuses.count)"
    }

    /// Starts over (a test's stand-in records change under it).
    func forget() {
        folders = [:]
        lastLive = [:]
        samples = [:]
        live = [:]
        statuses = [:]
    }
    #endif
}
