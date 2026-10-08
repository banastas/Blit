// The welcome-back summary (PRD R5.11): back at the Mac after four hours or
// more (the screen unlocked, the Mac awake, or the keyboard and mouse used
// again), one notification says what happened meanwhile: what arrived (and
// whether it's all verified), what's being fetched now, what qBittorrent is
// still downloading, what stalled while you were away, missing episodes, and
// transfers that failed. A click opens the same in a sheet, where each arrival
// can be shown in its folder. Nothing new, no notification. Blit has to be
// running (the window can be closed), and fetching needs the Mac awake: after
// a night asleep, the summary waits for watch mode's first look (R5.10).

import AppKit
import CoreGraphics
import UserNotifications

@MainActor
@Observable
final class WelcomeBack {
    static let shared = WelcomeBack()

    /// A download that finished.
    struct Arrival: Identifiable, Equatable {
        let id = UUID()
        var time: Date
        var title: String
        var items: [String]
        var bytes: Int64
        var verified: Bool
        var failed: Bool
        var gap: String?
    }

    struct Summary: Equatable {
        var since: Date
        var arrived: [Arrival]
        var failed: [Arrival]
        /// Being fetched now: name, how far, seconds left.
        var fetching: [(name: String, fraction: Double, secondsLeft: Int?)]
        /// In qBittorrent, unfinished: still downloading, and stalled while you were away.
        var downloading: [(name: String, fraction: Double)]
        var stalled: [(name: String, since: Date?)]
        var gaps: [String]

        static func == (a: Summary, b: Summary) -> Bool {
            a.since == b.since && a.arrived == b.arrived && a.failed == b.failed && a.gaps == b.gaps
                && a.fetching.map(\.name) == b.fetching.map(\.name) && a.downloading.map(\.name) == b.downloading.map(\.name)
                && a.stalled.map(\.name) == b.stalled.map(\.name)
        }

        var isNews: Bool { !arrived.isEmpty || !failed.isEmpty || !fetching.isEmpty || !stalled.isEmpty }
    }

    /// The last summary, and whether its sheet is up.
    private(set) var latest: Summary?
    var showing = false

    @ObservationIgnored private var arrivals: [Arrival] = []
    @ObservationIgnored private var awaySince: Date?
    @ObservationIgnored private var locked = false
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var poll: Task<Void, Never>?
    /// How long away before a summary (a test shortens it).
    @ObservationIgnored var awayAtLeast: TimeInterval = 4 * 3600
    @ObservationIgnored weak var transfers: TransferManager?

    static let category = "away-summary"

    // MARK: Arrivals

    /// A download finished (with the missing-episode line, if one was said).
    func noteFinished(_ job: TransferJob, gap: String?) {
        guard job.lane == .download, !job.isOperation else { return }
        let failed = job.status != .finished || !job.failures.isEmpty
        arrivals.append(Arrival(time: job.finishedAt ?? Date(), title: TransferNotifications.itemLabel(job),
                                items: ArrivalNotifications.landed(job).map(\.path), bytes: job.totalBytes,
                                verified: !failed && job.sizeOnlyCount == 0 && job.filesVerified > 0, failed: failed, gap: gap))
        // A week is plenty.
        arrivals.removeAll { Date().timeIntervalSince($0.time) > 7 * 86_400 }
        if arrivals.count > 500 { arrivals.removeFirst(arrivals.count - 500) }
    }

    // MARK: Away and back

    func start() {
        guard observers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        let workspace = NSWorkspace.shared.notificationCenter
        observers = [
            distributed.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.locked = true; self?.left(at: Date()) }
            },
            distributed.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.locked = false; self?.cameBack() }
            },
            workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.left(at: Date()) }
            },
            workspace.addObserver(forName: NSWorkspace.sessionDidResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.left(at: Date()) }
            },
            workspace.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.locked == false { self?.cameBack() } }
            },
        ]
        // Away without locking or sleeping (a Mac mini left on): the keyboard
        // and mouse idle, then used again.
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard let self else { return }
                let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
                if idle >= 600 {
                    self.left(at: Date().addingTimeInterval(-idle))
                } else if idle < 45, !self.locked {
                    self.cameBack()
                }
            }
        }
    }

    private func left(at time: Date) {
        if awaySince.map({ time < $0 }) ?? true { awaySince = time }
    }

    private func cameBack() {
        guard let since = awaySince else { return }
        awaySince = nil
        guard Date().timeIntervalSince(since) >= awayAtLeast else { return }
        Task { await present(since: since) }
    }

    /// Composes the summary since `since` and posts it, if there's news.
    func present(since: Date) async {
        await waitForWatch(since: Date())
        guard let summary = await compose(since: since), summary.isNews else { return }
        latest = summary
        await post(summary)
    }

    /// After a sleep, watch mode looks again as soon as it can: the summary
    /// waits for that (a minute and a half at most), so it can say what's
    /// being fetched.
    private func waitForWatch(since back: Date) async {
        guard let watch = SeedboxWatch.shared else { return }
        for _ in 0..<90 {
            let due = watch.rules.filter(\.enabled).filter { (watch.states[$0.id]?.lastCheck ?? .distantPast) < back }
            if due.isEmpty { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func compose(since: Date) async -> Summary? {
        let recent = arrivals.filter { $0.time >= since }
        var summary = Summary(since: since, arrived: recent.filter { !$0.failed }, failed: recent.filter(\.failed),
                              fetching: [], downloading: [], stalled: [], gaps: recent.compactMap(\.gap))
        for job in transfers?.transferJobs ?? [] where job.lane == .download && (job.isActive || job.status == .queued) {
            summary.fetching.append((job.title, job.progress, job.secondsLeft))
        }
        // qBittorrent's unfinished torrents in watched folders.
        if let watch = SeedboxWatch.shared, let library = TorrentLibrary.shared {
            for rule in watch.rules where rule.enabled {
                guard let records = await library.recordsFolder(for: rule.source), let path = await library.absolutePath(rule.source),
                      let torrents = await library.torrents(in: records, on: rule.source) else { continue }
                for torrent in torrents where !torrent.resume.finished && !torrent.resume.stopped
                    && TorrentStatusBoard.samePath(torrent.resume.savePath, path) {
                    let name = torrent.placed.sorted().first ?? torrent.id
                    // Its note is up to an hour old: two hours quiet is stalled.
                    let quiet = torrent.resume.lastDownload.map { Date().timeIntervalSince($0) } ?? .infinity
                    if quiet < 2 * 3600 {
                        summary.downloading.append((name, torrent.resume.fraction))
                    } else if let last = torrent.resume.lastDownload, last >= since {
                        summary.stalled.append((name, last))
                    }
                }
            }
        }
        return summary
    }

    // MARK: Saying it

    static func text(_ summary: Summary) -> (title: String, subtitle: String, body: String) {
        let bytes = summary.arrived.reduce(Int64(0)) { $0 + $1.bytes }.formatted(.byteCount(style: .file))
        let subtitle: String
        if summary.arrived.isEmpty {
            subtitle = "Nothing new arrived"
        } else {
            let verified = summary.arrived.allSatisfy(\.verified)
            subtitle = "\(summary.arrived.count) arrived · \(bytes)" + (verified ? ", all verified" : "")
        }
        var lines: [String] = []
        if !summary.fetching.isEmpty {
            let left = summary.fetching.compactMap(\.secondsLeft).max()
            lines.append("Fetching \(summary.fetching.count) now" + (left.map { ", about " + TransferNotifications.duration(TimeInterval($0)) } ?? "") + ".")
        }
        if !summary.downloading.isEmpty {
            let shown = summary.downloading.prefix(3).map { "\(Int(($0.fraction * 100).rounded(.down)))%" }.joined(separator: ", ")
            lines.append("Still downloading in qBittorrent: \(summary.downloading.count) (\(shown)\(summary.downloading.count > 3 ? ", …" : "")).")
        }
        if !summary.stalled.isEmpty {
            lines.append("Stalled while you were away: \(summary.stalled.count).")
        }
        lines += summary.gaps
        if !summary.failed.isEmpty {
            lines.append(summary.failed.count == 1 ? "1 transfer failed." : "\(summary.failed.count) transfers failed.")
        }
        return ("While you were away", subtitle, lines.joined(separator: "\n"))
    }

    private func post(_ summary: Summary) async {
        guard !TransferManager.isIsolated else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let text = Self.text(summary)
        let content = UNMutableNotificationContent()
        content.title = text.title
        content.subtitle = text.subtitle
        content.body = text.body
        content.categoryIdentifier = Self.category
        content.threadIdentifier = "away"
        content.userInfo = ["away": true]
        try? await center.add(UNNotificationRequest(identifier: "away-\(UUID().uuidString)", content: content, trigger: nil))
    }

    #if DEBUG
    /// Away since `time`, then back (a test: no lock or sleep needed).
    func simulateAway(since time: Date) { left(at: time) }
    func simulateBack() { cameBack() }

    /// The ledger, emptied (a test).
    func forget() {
        arrivals = []
        latest = nil
    }

    /// Shows `summary` as a click on its notification would (a test).
    func show(_ summary: Summary) {
        latest = summary
        showing = true
    }
    #endif
}
