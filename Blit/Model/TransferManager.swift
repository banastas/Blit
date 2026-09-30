// Transfers started by drag and drop (PRD R2.10): a queue with two lanes, one
// download and one local copy at a time (they use different links), using
// BlitKit's parallel verified download (server → local) or verified copy
// (local → local, cloning within one APFS volume).

import BlitLocal
import BlitRemote
import BlitSFTP
import AppKit
import CoreTransferable
import Foundation
import Network
import Observation
import UniformTypeIdentifiers
import UserNotifications

extension UTType {
    /// Locations dragged within Blit (declared in Support/Info.plist).
    static let blitLocations = UTType(exportedAs: "com.banastas.blit.locations")
}

struct TransferPayload: Codable, Transferable {
    var locations: [BrowseLocation]
    /// Which locations are folders (so Favorites can accept only folders).
    var folders: [BrowseLocation]? = nil
    /// The row this payload was dragged from (a multi-row drag makes one per row).
    var primary: BrowseLocation? = nil

    /// The dragged row's local file or folder, for Finder and other apps.
    var primaryFileURL: URL? { (primary ?? locations.first)?.localURL }

    static var transferRepresentation: some TransferRepresentation {
        // To Finder and other apps (PRD R2.3): the dragged row's file itself,
        // first, because apps take the first type they can use. (With Blit's
        // own type first, Finder saved a "Blit Locations" data file instead of
        // the file; a plain URL proxy reached Finder as a web link it ignored.)
        FileRepresentation(exportedContentType: .item) { payload in
            SentTransferredFile(payload.primaryFileURL ?? URL(fileURLWithPath: "/"), allowAccessingOriginalFile: true)
        }
        .exportingCondition { $0.primaryFileURL != nil }
        // Within Blit: every location, local or on a server (Blit's drop
        // targets read this type first). Hidden from other apps, which would
        // save it as a "Blit Locations" file rather than take the file itself.
        CodableRepresentation(contentType: .blitLocations)
            .visibility(.ownProcess)
        // From Finder: a dropped file URL becomes a local location, so every
        // drop target (rows, sidebar, path bar) accepts it.
        ProxyRepresentation(importing: { (url: URL) in TransferPayload(locations: [.local(url)]) })
    }
}

/// Source files whose copies were verified by SHA-256, so a move may remove
/// them. Filled from the engines' event callbacks, which run off the main actor.
final class VerifiedSources: @unchecked Sendable {
    /// A verified source with its size and modification time when it was
    /// verified; removal re-checks them, so a file rewritten since is kept.
    struct Remote: Hashable, Sendable, Codable {
        let pathBytes: [UInt8]
        let size: UInt64
        let modificationTime: UInt32?
        var path: RemotePath { RemotePath(bytes: pathBytes) }
    }
    struct Local: Hashable, Sendable, Codable { let path: String; let size: UInt64; let modificationTime: Date? }

    private let lock = NSLock()
    private var local: [Local] = []
    private var remote: [Remote] = []

    func record(_ event: TransferEvent) {
        switch event {
        case .fileFinished(_, .sha256), .fileFinished(_, .alreadyPresentVerified): break
        default: return
        }
        guard case .fileFinished(let file, _) = event else { return }
        lock.withLock { remote.append(Remote(pathBytes: file.path.bytes, size: file.size, modificationTime: file.modificationTime)) }
    }

    func record(_ event: CopyEvent) {
        switch event {
        case .fileFinished(let file, .nas), .fileFinished(let file, .readBack), .fileFinished(let file, .alreadyPresentVerified):
            lock.withLock { local.append(Local(path: file.path, size: file.size, modificationTime: file.modificationTime)) }
        default: break
        }
    }

    /// Takes the recorded sources (each once), leaving the ledger empty.
    func takeLocal() -> [Local] { lock.withLock { defer { local = [] }; return local.uniqued() } }
    func takeRemote() -> [Remote] { lock.withLock { defer { remote = [] }; return remote.uniqued() } }

    /// For saving with the queue: verified sources not yet removed survive a
    /// quit and are removed (after re-checking) when the job runs again.
    func snapshot() -> (local: [Local], remote: [Remote]) { lock.withLock { (local.uniqued(), remote.uniqued()) } }
    func add(local: [Local] = [], remote: [Remote] = []) {
        lock.withLock {
            self.local += local
            self.remote += remote
        }
    }
}

/// A thread-safe flag the copy engine checks between blocks.
final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ on: Bool) { lock.withLock { value = on } }
    var isSet: Bool { lock.withLock { value } }
}

struct LogLine: Identifiable {
    let id = UUID()
    let time = Date()
    let text: String
    let isFailure: Bool
}

@MainActor
@Observable
final class TransferJob: Identifiable {
    enum Kind {
        case download(ServerConfig), copy
        /// A file operation shown in the strip while it runs (delete, move,
        /// duplicate…): progress counts items, not bytes. `done` is the past
        /// tense for the summary ("DELETED").
        case operation(verb: String, done: String)
    }
    enum Status: Equatable {
        case queued, preparing, running, finished, failed(String)
        /// Waiting to retry after a recoverable failure (connection lost, drive unmounted).
        case waiting(until: Date, reason: String)
        /// The destination doesn't have room; continues by itself once it does (PRD R5.8).
        case waitingForSpace(String)
        /// Held by the user (PRD R5.2); resumes where it left off.
        case paused
        /// Stopped by the user; partial files stay so a Retry resumes them.
        case cancelled
    }

    /// What the user asked a running job to do.
    enum StopRequest { case pause, cancel }

    let id = UUID()
    let kind: Kind
    let sources: [BrowseLocation]
    let destination: URL
    let title: String
    let destinationName: String

    var status: Status = .queued {
        didSet { if status != .running { inFlight = [] } }
    }
    /// Files being transferred right now (relative paths), for the file list's
    /// Status column.
    var inFlight: Set<String> = []
    /// How each finished file was verified ("server-sha256", "size-only"…),
    /// by relative path, for the Status column.
    var outcomes: [String: String] = [:]
    var totalBytes: Int64 = 0
    var resumedBytes: Int64 = 0
    var fileCount = 0
    var filesFinished = 0
    var filesVerified = 0
    var filesAlreadyPresent = 0
    /// Bytes of files that were already at the destination (count as done).
    var presentBytes: Int64 = 0
    /// Brought back from a previous run (Blit quit or the Mac restarted).
    var restored = false
    /// Retry attempt (0 for the first run). Later attempts don't re-count resumed bytes.
    var attempt = 0
    /// Files already counted, so a retry's "already present" doesn't count them twice.
    var completedPaths: Set<String> = []
    /// Per-connection (download) or per-stream (copy) throughput, MB/s.
    var connectionRates: [Double] = []
    @ObservationIgnored var connectionCounters: [ByteCounter] = []
    var failures: [String] = []
    var connections = 0
    var link = ""
    var rate = 0.0
    var peakRate = 0.0
    var history: [Double] = []
    var log: [LogLine] = []
    /// Files whose bytes are all in, waiting on verification, with when that began.
    var verifying: [String: Date] = [:]
    /// Server-side hashing in progress: bytes hashed so far and file sizes, by
    /// relative path (where the server reports progress).
    var hashed: [String: UInt64] = [:]
    var hashSizes: [String: UInt64] = [:]
    /// Everything hashed so far (for the hash rate), and that rate in MB/s.
    @ObservationIgnored var hashedTotal: UInt64 = 0
    var hashRate = 0.0
    var startedAt: Date?
    var finishedAt: Date?
    @ObservationIgnored let counter = ByteCounter()

    init(kind: Kind, sources: [BrowseLocation], destination: URL, title: String, destinationName: String) {
        self.kind = kind
        self.sources = sources
        self.destination = destination
        self.title = title
        self.destinationName = destinationName
    }

    var transferred: Int64 { Int64(counter.total) + resumedBytes + presentBytes }

    /// Histogram scale: the download peak, or (once only checksums remain and
    /// the bars show the server's hash rate) the largest bar shown.
    var histogramScale: Double {
        max(isVerifyingOnly ? (history.suffix(60).max() ?? 1) : peakRate, 1)
    }

    /// All bytes are in and files are waiting on their checksums.
    var isVerifyingOnly: Bool { isActive && !verifying.isEmpty && transferred >= totalBytes }

    /// Files the server is hashing, with how far along each is.
    var hashing: [(name: String, fraction: Double)] {
        hashed.keys.sorted().map { name in
            (name, min(1, Double(hashed[name] ?? 0) / Double(max(hashSizes[name] ?? 1, 1))))
        }
    }

    /// Bytes hashed and to hash across the files waiting on their checksums,
    /// where progress is reported (the server, the NAS or a read-back).
    var verifyBytes: (done: UInt64, total: UInt64)? {
        let names = verifying.keys.filter { hashSizes[$0] != nil }
        let total = names.reduce(UInt64(0)) { $0 + (hashSizes[$1] ?? 0) }
        guard total > 0 else { return nil }
        let done = names.reduce(UInt64(0)) { $0 + min(hashed[$1] ?? 0, hashSizes[$1] ?? 0) }
        return (done, total)
    }

    /// How far verification has got, where it reports progress.
    var verifyProgress: Double? {
        verifyBytes.map { Double($0.done) / Double($0.total) }
    }

    /// The average rate over the last 15 seconds (the hash rate while only
    /// checksums remain), steadier than `rate` for estimates; nil before any.
    var recentRate: Double? {
        let recent = history.suffix(15)
        return recent.isEmpty ? nil : recent.reduce(0, +) / Double(recent.count)
    }

    /// Seconds left for this job at its recent rate: the bytes still to move,
    /// then, once they're across, the checksums still to run. For the menu bar,
    /// which shouldn't jump with every sample.
    var secondsLeft: Int? {
        guard let rate = recentRate, rate > 0.5 else { return nil }
        if isVerifyingOnly {
            guard let bytes = verifyBytes else { return nil }
            return Int(Double(bytes.total - bytes.done) / (rate * 1e6))
        }
        return Int(Double(max(totalBytes - transferred, 0)) / (rate * 1e6))
    }

    /// Seconds until the waiting files are verified, at the current hash rate.
    var verifySecondsLeft: Int? {
        guard hashRate > 0.5 else { return nil }
        let left = verifying.keys.reduce(UInt64(0)) { total, name in
            guard let size = hashSizes[name] else { return total }
            return total + (size - min(hashed[name] ?? 0, size))
        }
        return Int(Double(left) / (hashRate * 1e6))
    }
    /// Every file was already there; nothing was transferred.
    var allAlreadyPresent: Bool { fileCount > 0 && filesAlreadyPresent == fileCount }
    var progress: Double {
        if isOperation { return fileCount > 0 ? min(1, Double(filesFinished) / Double(fileCount)) : 0 }
        return totalBytes > 0 ? min(1, Double(transferred) / Double(totalBytes)) : 0
    }
    var isOperation: Bool {
        if case .operation = kind { return true }
        return false
    }
    /// Downloads and local copies run in separate lanes, one of each at a time:
    /// they use different links (internet vs. the home network).
    enum Lane: Hashable { case download, copy }
    /// Whether data is leaving this Mac: a copy onto a network share. The
    /// menu bar arrow and the ▲/▼ glyphs point up for these, and down for
    /// downloads and copies between drives on this Mac.
    var isOutgoing: Bool {
        if case .copy = kind { return VolumeKinds.isNetwork(destination) }
        return false
    }
    /// ▲ out to a share, ▼ into this Mac; ▲ for file operations (no direction).
    var directionGlyph: String {
        if case .operation = kind { return "▲" }
        return isOutgoing ? "▲" : "▼"
    }
    var lane: Lane {
        if case .download = kind { return .download }
        return .copy
    }
    /// Whether a retry should wait for the network: downloads always, copies
    /// only when a network share is involved. A copy between local drives
    /// mustn't be gated on an offline Mac's network (PRD R1.4).
    var needsNetwork: Bool {
        if case .download = kind { return true }
        return VolumeKinds.isNetwork(destination) || sources.contains { $0.localURL.map(VolumeKinds.isNetwork) ?? true }
    }
    /// Connections this job holds while running (closed on pause, cancel or quit).
    @ObservationIgnored var liveConnections: [SSHConnection] = []

    /// Set when the user pauses or cancels this job while it runs.
    var stopRequest: StopRequest? {
        didSet { stopFlag.set(stopRequest != nil) }
    }
    /// The same, readable from the engines' threads.
    @ObservationIgnored let stopFlag = StopFlag()
    var isPausedOrCancelled: Bool { status == .paused || status == .cancelled }
    var isActive: Bool {
        switch status {
        case .preparing, .running, .waiting, .waitingForSpace: true
        default: false
        }
    }
    /// How files are verified, for the HUD.
    /// How files are actually being verified, from what they finished with:
    /// weaker outcomes (size only, read-back instead of the NAS) are named.
    var verificationMethod: String {
        if !verifies { return "SIZE ONLY · VERIFY OFF" }
        if case .download = kind {
            if sizeOnlyCount > 0 { return filesVerified > 0 ? "SERVER SHA256 · \(sizeOnlyCount) SIZE ONLY" : "SIZE ONLY" }
            return "SERVER SHA256"
        }
        if nasVerified { return readBackCount > 0 ? "NAS SHA256 · \(readBackCount) READ-BACK" : "NAS SHA256" }
        return "READ-BACK"
    }
    var nasVerified = false
    /// Files that finished with a weaker check than the job's method.
    var sizeOnlyCount = 0
    var readBackCount = 0
    /// Verification-class failures per file across attempts (SHA-256 mismatch,
    /// changed while transferring), so a file that keeps failing stops retrying.
    @ObservationIgnored var verificationFailureCounts: [String: Int] = [:]
    /// Include hidden files when walking folders (captured at drop time).
    var includeHidden = false
    /// A move (Cut, then Paste on another drive or from a server): each source
    /// file is removed once its copy is verified by SHA-256. Anything not
    /// verified that way stays where it was.
    var deleteSources = false
    /// While waiting for space: bytes in the Trash on the destination drive,
    /// which emptying would free (the strip offers it).
    var destinationTrashBytes: Int64 = 0
    /// Saved to the durable queue (false only for debug simulations).
    var persistent = true
    /// A problem shown in the strip instead of an alert (see notice(_:action:place:)).
    var notice: String?
    /// The route advisory (PRD R1.7): the transfer is going over Wi-Fi while a
    /// wired link is up. Never a failure — the copy itself is fine, just slower.
    var routeWarning: String?
    /// Round trip to the server (an SFTP stat), measured at connect and every
    /// 30 s during a download, for the Link data panel.
    var rttMilliseconds: Double?
    /// Files whose SHA-256 the server answered from its hash cache (Link panel).
    var hashCacheHits = 0
    /// The "server disk bound" hint has been shown for this job.
    @ObservationIgnored var notedDiskBound = false
    /// Blit is quitting: files cut off as its connections close aren't failures
    /// (they resume on the next launch), so they're kept out of the log.
    @ObservationIgnored var isShuttingDown = false
    /// Retry Now: ends the backoff wait (and waits for the network or a drive) early.
    @ObservationIgnored var retryNowRequested = false
    /// What to do with files already at the destination (PRD R5.3), chosen in
    /// Settings when the transfer was queued.
    var existsRule: ExistsRule = TransferJob.defaultExistsRule
    /// Verify each file by SHA-256 (Settings › Verify files); off means a size
    /// check only. Moves always verify: see `verifies`.
    var verify = TransferJob.defaultVerify
    /// Files that finished with a size check because verification is off (by
    /// choice, unlike `sizeOnlyCount`, which is the server being unable to hash).
    var unverifiedCount = 0

    /// Whether files are verified: always for a move, since its sources are only
    /// removed once their copies' SHA-256 has matched.
    var verifies: Bool { verify || deleteSources }

    static var defaultVerify: Bool { UserDefaults.standard.string(forKey: "verifyFiles") != "sizeOnly" }

    static var defaultExistsRule: ExistsRule {
        UserDefaults.standard.string(forKey: "existsRule").flatMap(ExistsRule.init(rawValue:)) ?? .skipIfSameSize
    }
    @ObservationIgnored let verifiedSources = VerifiedSources()
    var removedSources = 0
    /// Source roots (as dropped) that a move has removed entirely, so a retry
    /// doesn't list them again (a remote "no such file" is otherwise permanent).
    var removedRoots = Set<String>()
    /// The source's folders and symlinks as last listed (PRD R3.1): empty
    /// folders and links are recreated, and a move cleans the folders up.
    @ObservationIgnored var remoteSourceDirectories: [RemotePath] = []
    @ObservationIgnored var localSourceDirectories: [String] = []
    @ObservationIgnored var localSourceSymlinks: [LocalTree.Symlink] = []

    func note(_ text: String, failure: Bool = false) {
        log.append(LogLine(text: text, isFailure: failure))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

@MainActor
@Observable
final class TransferManager {
    private(set) var jobs: [TransferJob] = []
    /// Called when a job finishes (to refresh browsers showing its destination
    /// or, for a move, its sources).
    @ObservationIgnored var onFinished: ((TransferJob) -> Void)?
    @ObservationIgnored private let servers: ServerStore
    @ObservationIgnored private let verifier: BlitHostKeyVerifier
    /// The job running in each lane, and its task.
    @ObservationIgnored private var runningJobs: [TransferJob.Lane: TransferJob] = [:]
    @ObservationIgnored private var runTasks: [TransferJob.Lane: Task<Void, Never>] = [:]
    /// Jobs running right now (keeps the Mac awake while any is).
    @ObservationIgnored private var activeRuns = 0
    /// Every job finished so far in the current batch verified its files.
    @ObservationIgnored private var batchVerified = true
    /// Totals for the current batch (until the queue drains), for its summary.
    struct Batch { var jobs = 0; var bytes: Int64 = 0; var failed = 0; var sizeOnly = 0; var unverified = 0; var started: Date? }
    @ObservationIgnored private var batch = Batch()

    /// Settings: a notification per transfer (default), or only when the queue
    /// finishes and when something needs attention.
    private var notifyEachTransfer: Bool {
        UserDefaults.standard.object(forKey: "notifyEachTransfer") as? Bool ?? true
    }

    @ObservationIgnored private var isQuitting = false
    @ObservationIgnored private var notificationProblemReported = false
    /// Held while transferring so the Mac doesn't idle-sleep (PRD R5.6).
    @ObservationIgnored private var keepAwake: NSObjectProtocol? {
        didSet { isKeepingAwake = keepAwake != nil }
    }
    /// Idle sleep is held off while transfers run (PRD R5.6); shown in the menu bar panel.
    private(set) var isKeepingAwake = false
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    var hasActiveWork: Bool { jobs.contains { $0.isActive } }

    /// Called when Blit is quitting mid-transfer: keeps the queue (including the
    /// running job) saved for next launch, then closes connections so the
    /// engines stop promptly. Resume data is already on disk.
    func prepareForQuit() async {
        saveQueue()
        isQuitting = true
        for job in jobs { job.isShuttingDown = true }
        let connections = jobs.flatMap(\.liveConnections)
        for job in jobs { job.liveConnections.removeAll() }
        await withTaskGroup(of: Void.self) { group in
            for connection in connections { group.addTask { await connection.close() } }
            group.addTask { try? await Task.sleep(for: .seconds(1)) }
            await group.next()
        }
    }

    init(servers: ServerStore, verifier: BlitHostKeyVerifier) {
        self.servers = servers
        self.verifier = verifier
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.jobs.first(where: \.isActive)?.note("WOKE FROM SLEEP · CHECKING CONNECTIONS")
            }
        }
    }

    /// The full HUD is open (click the count in the condensed strip). It opens
    /// by itself when a transfer starts (Settings), unless collapsed during
    /// the current batch.
    var isExpanded = false
    @ObservationIgnored private var collapsedThisBatch = false

    /// Collapses the HUD; it stays collapsed until the current transfers end.
    func collapse() {
        isExpanded = false
        if hasActiveWork { collapsedThisBatch = true }
    }

    /// The queue finished and everything checked out: the full HUD steps back
    /// to the strip after a moment, so the ✓ registers first. Problems (and
    /// size-only results) keep it open, and new work arriving meanwhile does too.
    private func collapseAfterSuccess() {
        guard isExpanded else { return }
        Task {
            try? await Task.sleep(for: .seconds(2))
            guard !jobs.contains(where: { !$0.isOperation && ($0.isActive || $0.status == .queued) }) else { return }
            isExpanded = false
        }
    }

    private func expandForTransfer() {
        let wanted = UserDefaults.standard.object(forKey: "expandHUDOnTransfer") as? Bool ?? true
        if !jobs.contains(where: { $0.isActive && !$0.isOperation }) { collapsedThisBatch = false }
        if wanted, !collapsedThisBatch { isExpanded = true }
    }
    /// Files handed to Blit from Finder (Services › Send to Blit…), waiting
    /// for the user to pick a destination.
    var pendingExternalFiles: [URL] = []

    /// The job the strip shows: a running file operation (so a delete shows
    /// over a long download while it runs), else the transfer that's been
    /// running longest, so the other lane starting a job doesn't take over;
    /// else the most recent.
    var featured: TransferJob? {
        if let pinnedJobID, let pinned = jobs.first(where: { $0.id == pinnedJobID }) { return pinned }
        let active = jobs.filter(\.isActive)
        let started = { (job: TransferJob) in job.startedAt ?? .distantPast }
        return active.filter(\.isOperation).max { started($0) < started($1) }
            ?? active.min { started($0) < started($1) }
            ?? jobs.last(where: { $0.status != .queued }) ?? jobs.first
    }

    /// Transfers running now, at most one per lane: outgoing (to a share) first.
    var activeTransfers: [TransferJob] {
        transferJobs.filter(\.isActive).sorted { a, b in
            a.isOutgoing != b.isOutgoing ? a.isOutgoing : a.lane == .download && b.lane != .download
        }
    }

    /// The menu bar's ✕: set when a transfer ends with failures, cleared when
    /// the menu bar panel is opened.
    var menuBarFailure = false
    /// The menu bar's ✓, for a minute after the queue finishes cleanly.
    private(set) var menuBarDone = false
    @ObservationIgnored private var menuBarDoneTask: Task<Void, Never>?

    private func showMenuBarDone() {
        menuBarDone = true
        menuBarDoneTask?.cancel()
        menuBarDoneTask = Task {
            try? await Task.sleep(for: .seconds(60))
            if !Task.isCancelled { menuBarDone = false }
        }
    }

    /// Stops the ✓ as soon as new work starts.
    private func clearMenuBarDone() {
        menuBarDoneTask?.cancel()
        menuBarDone = false
    }

    /// A job the user picked in the queue panel to show in the HUD.
    var pinnedJobID: UUID?

    /// Transfers (not file operations), in queue order, for the queue panel.
    var transferJobs: [TransferJob] { jobs.filter { !$0.isOperation } }

    // MARK: Queue control (PRD R5.2)

    /// The whole queue is held: nothing new starts, and the running job pauses.
    private(set) var queuePaused = UserDefaults.standard.bool(forKey: "queuePaused") {
        didSet { UserDefaults.standard.set(queuePaused, forKey: "queuePaused") }
    }

    private func isRunning(_ job: TransferJob) -> Bool { runningJobs[job.lane] === job }

    func pause(_ job: TransferJob) {
        if isRunning(job) {
            stop(job, .pause)
        } else if job.status == .queued {
            job.status = .paused
            saveQueue()
        }
    }

    func resume(_ job: TransferJob) {
        guard job.status == .paused else { return }
        job.stopRequest = nil
        job.status = .queued
        saveQueue()
        runNext()
    }

    func cancel(_ job: TransferJob) {
        if isRunning(job) {
            stop(job, .cancel)
        } else if job.status == .queued || job.status == .paused {
            job.status = .cancelled
            job.note("✕ CANCELLED", failure: true)
            saveQueue()
        }
    }

    /// Runs a failed or cancelled job again. Files already at the destination
    /// are skipped, so only what's missing transfers; partial files resume.
    func retry(_ job: TransferJob) {
        guard let index = jobs.firstIndex(where: { $0 === job }) else { return }
        switch job.status {
        case .failed, .cancelled: requeue(job, at: index)
        default: return
        }
    }

    private func requeue(_ job: TransferJob, at index: Int) {
        let fresh = TransferJob(kind: job.kind, sources: job.sources, destination: job.destination, title: job.title,
                                destinationName: job.destinationName)
        fresh.includeHidden = job.includeHidden
        fresh.deleteSources = job.deleteSources
        fresh.existsRule = job.existsRule
        fresh.removedRoots = job.removedRoots
        let verified = job.verifiedSources.snapshot()
        fresh.verifiedSources.add(local: verified.local, remote: verified.remote)
        fresh.note("RETRY REQUESTED")
        jobs[index] = fresh
        if pinnedJobID == job.id { pinnedJobID = fresh.id }
        saveQueue()
        runNext()
    }

    /// Moves a waiting job earlier (-1) or later (+1) among the waiting ones.
    func move(_ job: TransferJob, by step: Int) {
        let waiting = jobs.indices.filter { !jobs[$0].isOperation && (jobs[$0].status == .queued || jobs[$0].status == .paused) }
        guard let position = waiting.firstIndex(where: { jobs[$0] === job }) else { return }
        let target = position + step
        guard waiting.indices.contains(target) else { return }
        jobs.swapAt(waiting[position], waiting[target])
        saveQueue()
    }

    /// Moves a waiting job to the front of the queue (it starts next).
    func runSoon(_ job: TransferJob) {
        for _ in jobs.indices {
            let waiting = jobs.indices.filter { !jobs[$0].isOperation && (jobs[$0].status == .queued || jobs[$0].status == .paused) }
            guard let position = waiting.firstIndex(where: { jobs[$0] === job }), position > 0 else { return }
            move(job, by: -1)
        }
    }

    func pauseAll() {
        queuePaused = true
        for job in runningJobs.values { stop(job, .pause) }
    }

    func resumeAll() {
        queuePaused = false
        for job in jobs where job.status == .paused {
            job.stopRequest = nil
            job.status = .queued
        }
        saveQueue()
        runNext()
    }

    /// Stops the running job: its connections close (downloads end at once),
    /// the copy engine stops at its next block, and a retry wait is cut short.
    private func stop(_ job: TransferJob, _ request: TransferJob.StopRequest) {
        job.stopRequest = request
        let connections = job.liveConnections
        job.liveConnections.removeAll()
        for connection in connections { Task { await connection.close() } }
        runTasks[job.lane]?.cancel()
    }

    #if DEBUG
    /// Adds jobs without starting them (self-tests of queue rules).
    func debugAppend(_ newJobs: [TransferJob]) { jobs += newJobs }
    func debugRemove(_ old: [TransferJob]) { jobs.removeAll { job in old.contains { $0 === job } } }

    /// `-BlitFakeTransfer YES`: a simulated download in the HUD (percent ticking,
    /// connection rates changing) to reproduce layout issues without a server.
    func startFakeTransferIfRequested() {
        guard UserDefaults.standard.bool(forKey: "BlitFakeTransfer") else { return }
        let job = TransferJob(kind: .copy, sources: [.local(URL(fileURLWithPath: "/tmp/fake.mkv"))],
                              destination: URL(fileURLWithPath: "/tmp"), title: "FAKE.TRANSFER.2160P.MKV",
                              destinationName: "Somewhere")
        job.persistent = false
        job.status = .running
        job.startedAt = Date()
        job.fileCount = 1
        job.totalBytes = 4_000_000_000
        job.connections = 3
        job.link = "3× · 255K×32"
        job.connectionCounters = (0..<3).map { _ in ByteCounter() }
        job.note("FAKE TRANSFER FOR LAYOUT TESTING")
        jobs.append(job)
        isExpanded = true
        Task {
            var tick = 0
            while job.transferred < job.totalBytes {
                try? await Task.sleep(for: .milliseconds(250))
                tick += 1
                let chunk = Int.random(in: 4_000_000...8_000_000)
                job.counter.add(chunk)
                if tick % 4 == 0 {
                    job.rate = Double.random(in: 18...32)
                    job.peakRate = max(job.peakRate, job.rate)
                    job.history.append(job.rate)
                    if job.history.count > 60 { job.history.removeFirst() }
                    // The third connection stalls every other 5 s (its strip square dims).
                    let stalled = (tick / 20) % 2 == 1
                    job.connectionRates = (0..<3).map { $0 == 2 && stalled ? 0 : Double.random(in: 5...12) }
                }
            }
        }
    }
    #endif

    // MARK: File operations in the strip

    /// Starts showing a file operation. It appears only if it's still running
    /// after a moment, so instant renames and moves don't flash the strip.
    func beginOperation(_ verb: String, done: String, items: [String], destination: String, link: String) -> TransferJob {
        let job = TransferJob(kind: .operation(verb: verb, done: done), sources: [], destination: URL(fileURLWithPath: "/"),
                              title: Self.title(items), destinationName: destination)
        job.fileCount = items.count
        job.status = .running
        job.startedAt = Date()
        job.link = link
        job.connections = 1
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            if job.isActive, !jobs.contains(where: { $0 === job }) { jobs.append(job) }
        }
        return job
    }

    /// Ends a file operation. A clean one leaves the strip after a few seconds;
    /// one with problems stays until dismissed.
    func finishOperation(_ job: TransferJob) {
        job.status = job.failures.isEmpty ? .finished : .failed("\(job.failures.count) failed")
        job.finishedAt = Date()
        guard job.failures.isEmpty else {
            // A quick failure never reached the strip (it joins after 400 ms): show it now.
            if !jobs.contains(where: { $0 === job }) { jobs.append(job) }
            announce(job.failures.first ?? "")
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(4))
            jobs.removeAll { $0 === job }
            if jobs.isEmpty { isExpanded = false }
        }
    }
    var queuedCount: Int { jobs.filter { $0.status == .queued }.count }

    /// The whole queue at a glance (menu bar panel): bytes still to move in
    /// running and queued jobs whose size is known, and an ETA at the current
    /// combined rate.
    var queueTotals: (queued: Int, bytesLeft: Int64, eta: Int?) {
        let pending = transferJobs.filter { $0.isActive || $0.status == .queued }
        let left = pending.reduce(Int64(0)) { $0 + max($1.totalBytes - $1.transferred, 0) }
        // Each lane drains at its own speed (the internet, the home network):
        // the queue is done when the slower lane is. A lane with bytes left
        // but no speed yet makes the whole estimate unknown.
        var eta: Int? = 0
        for lane in [TransferJob.Lane.download, .copy] {
            let inLane = pending.filter { $0.lane == lane }
            let bytes = inLane.reduce(Int64(0)) { $0 + max($1.totalBytes - $1.transferred, 0) }
            guard bytes > 0 else { continue }
            // While only checksums remain, the history holds the hash rate: use the peak.
            guard let running = inLane.first(where: \.isActive),
                  let rate = running.isVerifyingOnly ? running.peakRate : running.recentRate, rate > 0.5 else {
                eta = nil
                break
            }
            eta = max(eta ?? 0, Int(Double(bytes) / (rate * 1e6)))
        }
        return (queuedCount, left, left > 0 ? eta : nil)
    }

    /// One SFTP round trip in milliseconds (a stat of the home folder), or nil
    /// if it failed. During a download it includes queueing behind reads, which
    /// is the latency the transfer actually sees.
    nonisolated static func roundTrip(_ client: SFTPClient) async -> Double? {
        let start = ContinuousClock.now
        guard (try? await client.stat(RemotePath("."))) != nil else { return nil }
        let elapsed = ContinuousClock.now - start
        return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
    }

    /// Ends a waiting job's backoff and tries again at once (the cause was fixed).
    func retryNow(_ job: TransferJob) {
        guard case .waiting = job.status else { return }
        job.retryNowRequested = true
    }

    /// A problem that needs no decision: a ✕ line in the strip that stays
    /// until dismissed, instead of an alert (PRD: no popups unless a decision
    /// is needed). `action` names what was tried ("RENAME"), `place` where.
    func notice(_ message: String, action: String, place: String = "") {
        let lines = message.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        let job = TransferJob(kind: .operation(verb: "FAILED", done: action), sources: [], destination: URL(fileURLWithPath: "/"),
                              title: action, destinationName: place)
        job.persistent = false
        job.notice = lines.joined(separator: " · ")
        job.failures = lines
        job.status = .failed(lines[0])
        job.startedAt = Date()
        job.finishedAt = Date()
        job.note("✕ \(job.notice!.uppercased())", failure: true)
        jobs.append(job)
        announce(message)
    }

    /// Speaks a problem for VoiceOver users, who don't see the strip change.
    private func announce(_ message: String) {
        guard !message.isEmpty, let window = NSApp.mainWindow else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func dismissFinished() {
        jobs.removeAll { !$0.isActive && $0.status != .queued && $0.status != .paused }
        if let pinnedJobID, !jobs.contains(where: { $0.id == pinnedJobID }) { self.pinnedJobID = nil }
        if jobs.isEmpty { isExpanded = false }
    }

    /// Queues a transfer of `sources` into `destination`. Returns a message
    /// if it can't be done.
    func enqueue(_ sources: [BrowseLocation], to destination: BrowseLocation, destinationName: String,
                 includeHidden: Bool = false, move: Bool = false, existsRule: ExistsRule? = nil) -> String? {
        // After the trial (or a revoked key), new transfers don't start; queued
        // and running ones still finish (PRD open question 12).
        let license = LicenseManager.shared
        license.refresh()
        guard license.canStartTransfers else { return license.lockedMessage }
        guard let folder = destination.localURL else {
            return "Uploading to a server isn't supported yet. Drop onto a local folder, drive or NAS share."
        }
        // An item inside another selected folder goes with that folder; a
        // duplicate transfer would then log spurious KEPT errors on a move.
        let unique = sources.uniqued()
        let sources = unique.filter { item in
            !unique.contains { $0 != item && FileOperations.location($0, contains: item) }
        }
        let remote = sources.filter { $0.serverID != nil }
        let local = sources.compactMap(\.localURL)
        if Set(remote.compactMap(\.serverID)).count > 1 { return "Drag from one server at a time." }
        // By identity, not spelling: a symlinked path into the folder is still inside it.
        if sources.contains(where: { FileOperations.location($0, contains: .local(folder)) }) {
            return "Can't copy a folder into itself."
        }
        if let id = remote.first?.serverID {
            guard let server = servers.server(id) else { return "That server no longer exists." }
            let job = TransferJob(kind: .download(server), sources: remote, destination: folder,
                                  title: Self.title(remote.map(\.lastComponent)), destinationName: destinationName)
            job.includeHidden = includeHidden
            job.deleteSources = move
            if let existsRule { job.existsRule = existsRule }   // the answer to Replace / Keep Both
            jobs.append(job)
        }
        if !local.isEmpty {
            let job = TransferJob(kind: .copy, sources: local.map { .local($0) }, destination: folder,
                                  title: Self.title(local.map(\.lastPathComponent)), destinationName: destinationName)
            job.deleteSources = move
            if let existsRule { job.existsRule = existsRule }   // the answer to Replace / Keep Both
            jobs.append(job)
        }
        expandForTransfer()
        saveQueue()
        runNext()
        return nil
    }

    // MARK: Durable queue (PRD R5.1)

    private struct SavedJob: Codable {
        var serverID: UUID?
        var sources: [BrowseLocation]
        var destination: URL
        var title: String
        var destinationName: String
        var includeHidden: Bool
        var deleteSources: Bool?
        var verifiedLocal: [VerifiedSources.Local]?
        var verifiedRemote: [VerifiedSources.Remote]?
        var removedRoots: [String]?
        var paused: Bool?
        var existsRule: ExistsRule?
        var verify: Bool?
    }

    private static var queueURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Blit/queue.json")
    }

    /// Saves unfinished jobs, so a quit or restart doesn't lose them.
    /// `-BlitIsolatedQueue YES` (debug test copies): don't read or write the saved
    /// queue, so a test copy running beside the installed Blit can't start its
    /// jobs or overwrite its queue.
    static var isIsolated: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "BlitIsolatedQueue")
        #else
        false
        #endif
    }

    private func saveQueue() {
        // While quitting, the running job fails as its connections close; keep it saved.
        guard !isQuitting, !Self.isIsolated else { return }
        let pending = jobs.filter { $0.persistent && !$0.isOperation && ($0.status == .queued || $0.status == .paused || $0.isActive) }.map { job -> SavedJob in
            var serverID: UUID?
            if case .download(let server) = job.kind { serverID = server.id }
            let verified = job.verifiedSources.snapshot()
            return SavedJob(serverID: serverID, sources: job.sources, destination: job.destination, title: job.title,
                            destinationName: job.destinationName, includeHidden: job.includeHidden,
                            deleteSources: job.deleteSources,
                            verifiedLocal: verified.local.isEmpty ? nil : verified.local,
                            verifiedRemote: verified.remote.isEmpty ? nil : verified.remote,
                            removedRoots: job.removedRoots.isEmpty ? nil : Array(job.removedRoots),
                            paused: job.status == .paused ? true : nil, existsRule: job.existsRule,
                            verify: job.verify ? nil : false)
        }
        let url = Self.queueURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(pending) { try? data.write(to: url, options: .atomic) }
    }

    /// Brings back jobs that hadn't finished when Blit last quit. Downloads resume
    /// from their .blitpart files; files already complete are skipped.
    func restoreQueue() {
        guard jobs.isEmpty, !Self.isIsolated, let data = try? Data(contentsOf: Self.queueURL),
              let saved = try? JSONDecoder().decode([SavedJob].self, from: data), !saved.isEmpty else { return }
        for s in saved {
            let kind: TransferJob.Kind
            if let id = s.serverID {
                guard let server = servers.server(id) else {
                    // Keep it visible rather than silently dropping it (PRD R5.1).
                    let lost = TransferJob(kind: .copy, sources: s.sources, destination: s.destination, title: s.title,
                                           destinationName: s.destinationName)
                    lost.status = .failed("its server no longer exists")
                    lost.note("✕ NOT RESTORED · ITS SERVER NO LONGER EXISTS", failure: true)
                    lost.failures.append("Not restored: the server for this transfer was removed.")
                    jobs.append(lost)
                    continue
                }
                kind = .download(server)
            } else {
                kind = .copy
            }
            let job = TransferJob(kind: kind, sources: s.sources, destination: s.destination, title: s.title,
                                  destinationName: s.destinationName)
            job.includeHidden = s.includeHidden
            job.deleteSources = s.deleteSources ?? false
            job.verifiedSources.add(local: s.verifiedLocal ?? [], remote: s.verifiedRemote ?? [])
            job.removedRoots = Set(s.removedRoots ?? [])
            if s.paused == true { job.status = .paused }
            if let rule = s.existsRule { job.existsRule = rule }
            if let verify = s.verify { job.verify = verify }
            job.restored = true
            job.note("RESTORED FROM LAST SESSION · RESUMING")
            jobs.append(job)
        }
        expandForTransfer()
        saveQueue()
        runNext()
    }

    // MARK: Notifications (PRD R5.5)

    private func notify(_ job: TransferJob) async {
        // Test copies never notify: their jobs aren't the user's.
        guard !isQuitting, !Self.isIsolated else { return }
        let center = UNUserNotificationCenter.current()
        do {
            guard try await center.requestAuthorization(options: [.alert, .sound]) else { return }
        } catch {
            // Typically an ad-hoc signed build: macOS refuses notifications until the
            // app is signed with a development team. Say so once instead of failing silently.
            if !notificationProblemReported {
                notificationProblemReported = true
                job.note("✕ NOTIFICATIONS UNAVAILABLE · \(error.localizedDescription)".uppercased(), failure: true)
            }
            return
        }
        guard let content = TransferNotifications.content(for: job, eachTransfer: notifyEachTransfer) else { return }
        try? await center.add(UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil))
    }

    /// When the queue drains: one summary, if it held more than one transfer
    /// (or if per-transfer notifications are off).
    private func notifyBatch(_ batch: Batch) async {
        guard !isQuitting, !Self.isIsolated, batch.jobs > 0, batch.jobs > 1 || !notifyEachTransfer else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = TransferNotifications.batchContent(jobs: batch.jobs, bytes: batch.bytes, failed: batch.failed,
                                                         sizeOnly: batch.sizeOnly, unverified: batch.unverified,
                                                         elapsed: batch.started.map { Date().timeIntervalSince($0) })
        try? await center.add(UNNotificationRequest(identifier: "batch-\(UUID().uuidString)", content: content, trigger: nil))
    }

    private static func title(_ names: [String]) -> String {
        guard let first = names.first else { return "" }
        return names.count == 1 ? first : "\(first) +\(names.count - 1)"
    }

    /// Starts the next waiting job in each free lane (queue order within a lane).
    private func runNext() {
        guard !queuePaused else { return }
        for lane in [TransferJob.Lane.download, .copy] where runningJobs[lane] == nil {
            guard let job = jobs.first(where: { $0.status == .queued && $0.lane == lane && !isBlocked($0) }) else { continue }
            start(job)
        }
    }

    /// A copy waits for downloads queued ahead of it into its source (copying a
    /// pack to the NAS while it's still downloading would copy half of it).
    func isBlocked(_ job: TransferJob) -> Bool {
        guard job.lane == .copy, let index = jobs.firstIndex(where: { $0 === job }) else { return false }
        let sources = job.sources.compactMap { $0.localURL?.standardizedFileURL.path }
        return jobs[..<index].contains { earlier in
            guard earlier.lane == .download, earlier.status == .queued || earlier.isActive || earlier.status == .paused else { return false }
            let destination = earlier.destination.standardizedFileURL.path
            return sources.contains { $0 == destination || $0.hasPrefix(destination + "/") || destination.hasPrefix($0 + "/") }
        }
    }

    private func start(_ job: TransferJob) {
        let lane = job.lane
        clearMenuBarDone()
        if batch.started == nil { batch.started = Date() }
        runningJobs[lane] = job
        runTasks[lane] = Task {
            await run(job)
            runningJobs[lane] = nil
            runTasks[lane] = nil
            saveQueue()
            if job.isPausedOrCancelled {
                // Held or stopped by the user: no notification, no batch verdict.
                runNext()
                return
            }
            let jobVerified = job.status == .finished && job.failures.isEmpty && job.sizeOnlyCount == 0
                && (job.filesVerified > 0 || job.fileCount == 0)
            let jobFailed = job.status != .finished || !job.failures.isEmpty
            batchVerified = batchVerified && jobVerified
            batch.jobs += 1
            batch.bytes += job.totalBytes
            if jobFailed {
                batch.failed += 1
                menuBarFailure = true
            }
            batch.sizeOnly += job.sizeOnlyCount
            batch.unverified += job.unverifiedCount
            onFinished?(job)
            await notify(job)
            if !isQuitting, !jobs.contains(where: { !$0.isOperation && ($0.status == .queued || $0.isActive) }) {
                DockProgress.shared.finish(batch.failed > 0 ? .failed : batchVerified ? .verified : .plain)
                if batch.failed == 0 { showMenuBarDone() }
                if batch.failed == 0, batch.sizeOnly == 0 { collapseAfterSuccess() }
                await notifyBatch(batch)
                batchVerified = true
                batch = Batch()
            }
            runNext()
        }
    }

    /// Failure reasons a retry can't fix (from BlitKit's messages).
    private static let permanentMarkers = [
        "already exists", "same local name", "no such file", "permission denied", "status 2", "status 3",
        "server refused", "authentication failed", "host key", "no password", "nopassword", "no longer exists",
        "gave up after", "source kept", "unsafe name",
    ]

    static func isRetryable(_ reason: String) -> Bool {
        let r = reason.lowercased()
        return !permanentMarkers.contains { r.contains($0) }
    }

    /// How a source root is recorded in `removedRoots`.
    nonisolated static func rootKey(_ location: BrowseLocation) -> String {
        switch location {
        case .local(let url): url.standardizedFileURL.path
        case .remote(_, let bytes): String(decoding: bytes, as: UTF8.self)
        }
    }

    /// Delay before retry n (0-based); attempts that made progress reset n.
    private static let backoff: [Int] = [10, 30, 60, 120, 300]
    private static let maxAttemptsWithoutProgress = 5

    private func run(_ job: TransferJob) async {
        job.status = .preparing
        job.startedAt = Date()
        saveQueue()
        let sampler = Task { await sample(job) }
        defer { sampler.cancel() }
        activeRuns += 1
        if keepAwake == nil {
            keepAwake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                              reason: "Blit is transferring files")
        }
        defer {
            activeRuns -= 1
            if activeRuns == 0, let activity = keepAwake {
                ProcessInfo.processInfo.endActivity(activity)
                keepAwake = nil
            }
        }

        var stalled = 0
        while true {
            let before = job.counter.total
            var fatal: String?
            do {
                switch job.kind {
                case .download(let server): try await download(job, from: server)
                case .copy: try await copy(job)
                case .operation: return
                }
            } catch {
                fatal = "\(error)"
            }
            if let request = job.stopRequest {
                finishStop(job, request)
                break
            }
            if isQuitting { break }
            if fatal == nil, job.failures.isEmpty {
                job.status = .finished
                break
            }
            let reasons = fatal.map { [$0] } ?? job.failures
            // Out of space mid-transfer (another writer, a miscount): wait for room
            // instead of retrying into a full disk (PRD R5.8).
            if reasons.contains(where: Self.isOutOfSpace) {
                let remaining = UInt64(max(job.totalBytes - job.transferred, 0))
                guard await waitForSpace(job, needed: remaining) else {
                    if let request = job.stopRequest { finishStop(job, request) }
                    break
                }
                job.attempt += 1
                job.failures = []
                job.verifying = [:]
                job.status = .preparing
                job.note("RETRY \(job.attempt) · SPACE AVAILABLE")
                continue
            }
            // A drive or share that went away turns into "no such file"-style errors;
            // that's worth waiting for, whatever the message says (PRD R1.4).
            let missing = await missingVolumes(job)
            guard !missing.isEmpty || reasons.contains(where: Self.isRetryable) else {
                if let fatal { job.note("✕ \(fatal)".uppercased(), failure: true) }
                job.status = .failed(fatal ?? "\(job.failures.count) failed")
                break
            }
            stalled = job.counter.total > before ? 0 : stalled + 1
            guard stalled < Self.maxAttemptsWithoutProgress else {
                job.note("✕ GAVE UP AFTER \(stalled) ATTEMPTS WITHOUT PROGRESS", failure: true)
                job.status = .failed(fatal ?? "gave up after \(stalled) retries")
                break
            }
            let delay = Self.backoff[min(stalled, Self.backoff.count - 1)]
            let reason = missing.isEmpty
                ? Self.shortReason(reasons.first(where: Self.isRetryable) ?? "error")
                : "\(missing.joined(separator: ", ")) is unavailable"
            job.note("RETRY IN \(delay) S · \(reason)".uppercased(), failure: true)
            job.rate = 0
            job.connectionRates = []
            let until = Date().addingTimeInterval(TimeInterval(delay))
            job.status = .waiting(until: until, reason: reason)
            job.retryNowRequested = false
            // Sleeps in short steps so Retry Now (or pause/cancel) ends it early.
            while Date() < until, !job.retryNowRequested, job.stopRequest == nil, !isQuitting, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if !job.retryNowRequested {
                if job.needsNetwork { await waitForNetwork(job) }
                await waitForVolumes(job)
            }
            if job.retryNowRequested { job.note("RETRY NOW") }
            job.retryNowRequested = false
            if let request = job.stopRequest {
                finishStop(job, request)
                break
            }
            if isQuitting { break }
            job.attempt += 1
            job.failures = []
            job.verifying = [:]
            job.status = .preparing
            job.note("RETRY \(job.attempt) · RESUMING")
        }
        job.finishedAt = Date()
        job.rate = 0
    }

    // MARK: Free space (PRD R5.8)

    /// Kept free on the destination beyond what the transfer needs: 1 GB, or
    /// 2% of the volume if smaller (so a small USB stick isn't blocked forever).
    nonisolated static func spaceReserve(at url: URL) -> UInt64 {
        let capacity = (try? url.resourceValues(forKeys: [.volumeTotalCapacityKey]))?.volumeTotalCapacity.map { UInt64(max($0, 0)) }
        return min(1 << 30, (capacity ?? (50 << 30)) / 50)
    }

    nonisolated static func isOutOfSpace(_ reason: String) -> Bool {
        let r = reason.lowercased()
        return r.contains("no space left") || r.contains("not enough space") || r.contains("disk full")
    }

    nonisolated static func volumeID(_ url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    /// Bytes still to be written into `destination`: a file already there, or
    /// a part file (which reserves its full size when created), needs none.
    nonisolated static func bytesNeeded(_ files: [(relativePath: String, size: UInt64)], in destination: URL) -> UInt64 {
        let fm = FileManager.default
        return files.reduce(UInt64(0)) { total, file in
            let final = destination.appendingPathComponent(file.relativePath).path
            if fm.fileExists(atPath: final) || fm.fileExists(atPath: final + ".blitpart") { return total }
            return total + file.size
        }
    }

    /// Free space on the destination for writes, including space APFS can purge.
    nonisolated static func freeSpace(at url: URL) -> UInt64? {
        let important = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage.map { UInt64(max($0, 0)) }
        let plain = availableBytes(at: url.path)
        switch (important, plain) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }

    /// Waits until the destination has room for `needed` bytes (plus a small
    /// reserve), showing why and notifying once. Returns false if the job was
    /// paused, cancelled or Blit is quitting meanwhile.
    private func waitForSpace(_ job: TransferJob, needed: UInt64) async -> Bool {
        guard needed > 0 else { return true }
        let destination = job.destination
        let volume = (try? destination.resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
            ?? job.destinationName
        var waited = false
        let reserve = await Task.detached { Self.spaceReserve(at: destination) }.value
        while true {
            if job.stopRequest != nil || isQuitting || Task.isCancelled { return false }
            let free = await Task.detached { Self.freeSpace(at: destination) }.value ?? .max
            if free >= needed + reserve {
                job.destinationTrashBytes = 0
                if waited { job.note("SPACE AVAILABLE ON \(volume.uppercased()) · CONTINUING") }
                return true
            }
            let short = needed + reserve - free
            let reason = "\(volume) needs \(TransferJob.bytes(Int64(short))) more"
            job.status = .waitingForSpace(reason)
            job.rate = 0
            if let trash = TrashService.volumeTrash(containing: destination) {
                job.destinationTrashBytes = await TrashService.contents(of: trash).bytes
            }
            if !waited {
                waited = true
                job.note("✕ WAITING FOR SPACE · \(reason.uppercased())", failure: true)
                await notifySpace(job, reason: reason)
            }
            try? await Task.sleep(for: .seconds(15))
        }
    }

    private func notifySpace(_ job: TransferJob, reason: String) async {
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "Waiting for space: \(job.title)"
        content.body = "\(reason). Blit continues by itself once there's room."
        content.sound = .default
        try? await center.add(UNNotificationRequest(identifier: "space-\(job.id.uuidString)", content: content, trigger: nil))
    }

    private func finishStop(_ job: TransferJob, _ request: TransferJob.StopRequest) {
        job.failures = []
        job.verifying = [:]
        job.rate = 0
        job.connectionRates = []
        switch request {
        case .pause:
            job.status = .paused
            job.note("‖ PAUSED · RESUMES WHERE IT LEFT OFF")
        case .cancel:
            job.status = .cancelled
            job.note("✕ CANCELLED · PARTIAL FILES KEPT FOR A RETRY", failure: true)
        }
    }

    /// "disconnected: no data from the server for 60 s" → "NO DATA FROM THE SERVER FOR 60 S"
    private static func shortReason(_ reason: String) -> String {
        let trimmed = reason.split(separator: ":", maxSplits: 1).last.map(String.init) ?? reason
        return String(trimmed.trimmingCharacters(in: .whitespaces).prefix(80))
    }

    /// Waits until macOS reports a usable network path, for at most 10 minutes
    /// (a local copy on an offline Mac mustn't wait forever); the retry then
    /// runs regardless and fails or succeeds on its own.
    private func waitForNetwork(_ job: TransferJob) async {
        if case .waiting(_, let reason) = job.status {
            job.status = .waiting(until: .distantPast, reason: "waiting for the network · " + reason)
        }
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
        }
        let monitor = NWPathMonitor()
        let once = Once()
        final class Box: @unchecked Sendable { var continuation: CheckedContinuation<Void, Never>? }
        let box = Box()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                box.continuation = continuation
                monitor.pathUpdateHandler = { path in
                    if path.status == .satisfied, once.claim() { continuation.resume() }
                }
                monitor.start(queue: .global(qos: .utility))
                DispatchQueue.global().asyncAfter(deadline: .now() + 600) {
                    if once.claim() { continuation.resume() }
                }
                if Task.isCancelled, once.claim() { continuation.resume() }
            }
        } onCancel: {
            // Paused or cancelled while waiting: stop waiting.
            if once.claim() { box.continuation?.resume() }
        }
        monitor.cancel()
    }

    /// Names of the job's destination and local source folders that are missing
    /// (an SSD unplugged, a NAS share unmounted). The checks run off the main
    /// actor: fileExists on a mounted-but-dead SMB path blocks for the smbfs
    /// timeout — exactly during the outage this waits out (PRD R1.4).
    private func missingVolumes(_ job: TransferJob) async -> [String] {
        let destinationPath = job.destination.path
        let destinationName = job.destinationName
        // A source a move already removed isn't "missing".
        let sources = job.sources.filter { !job.removedRoots.contains(Self.rootKey($0)) }.compactMap(\.localURL)
        return await Task.detached { () -> [String] in
            let fm = FileManager.default
            var missing: [String] = []
            if !fm.fileExists(atPath: destinationPath) { missing.append(destinationName) }
            // A missing file on a mounted drive isn't a missing drive: only an
            // unmounted volume counts.
            for url in sources {
                guard !fm.fileExists(atPath: url.path) else { continue }
                let parts = url.standardizedFileURL.pathComponents
                guard parts.count > 2, parts[1] == "Volumes", !fm.fileExists(atPath: "/Volumes/" + parts[2]) else { continue }
                if !missing.contains(parts[2]) { missing.append(parts[2]) }
            }
            return missing
        }.value
    }

    /// Waits (up to an hour) for missing drives or shares to come back.
    private func waitForVolumes(_ job: TransferJob) async {
        var noted = Set<String>()
        for round in 0..<720 {
            let missing = await missingVolumes(job)
            if missing.isEmpty || isQuitting || Task.isCancelled { return }
            for name in missing where noted.insert(name).inserted {
                job.note("WAITING FOR \(name.uppercased()) TO COME BACK", failure: true)
            }
            // A NAS share Blit knows how to mount: reconnect it (PRD R1.5), now
            // and every 30 s while it stays away.
            if round % 6 == 0 {
                let paths = [job.destination.path] + job.sources.compactMap { $0.localURL?.path }
                for share in Set(paths.compactMap(ShareMounter.missingShare(containing:))) {
                    job.note("RECONNECTING \((share as NSString).lastPathComponent.uppercased())")
                    if let problem = await ShareMounter.reconnect(share) {
                        if noted.insert("reconnect " + share).inserted { job.note("✕ \(problem.uppercased())", failure: true) }
                    } else {
                        job.note("RECONNECTED \((share as NSString).lastPathComponent.uppercased())")
                    }
                }
                if await missingVolumes(job).isEmpty { return }
            }
            // The countdown is over; say what it's really waiting for.
            job.status = .waiting(until: .distantPast, reason: "waiting for \(missing.joined(separator: ", ")) to come back · reconnect it")
            for _ in 0..<20 where !job.retryNowRequested && job.stopRequest == nil {
                try? await Task.sleep(for: .milliseconds(250))
            }
            if job.retryNowRequested || job.stopRequest != nil { return }
        }
    }

    /// Samples throughput once a second for the rate and histogram.
    private func sample(_ job: TransferJob) async {
        var last = (time: Date(), bytes: 0)
        var lastPer: [Int] = []
        var lastHashed: UInt64 = 0
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let now = Date()
            let bytes = job.counter.total
            let seconds = max(now.timeIntervalSince(last.time), 0.001)
            let rate = Double(bytes - last.bytes) / seconds / 1e6
            last = (now, bytes)
            let per = job.connectionCounters.map(\.total)
            if lastPer.count == per.count {
                job.connectionRates = zip(per, lastPer).map { Double($0 - $1) / seconds / 1e6 }
            }
            lastPer = per
            let hashedNow = job.hashedTotal
            job.hashRate = Double(hashedNow - min(lastHashed, hashedNow)) / seconds / 1e6
            lastHashed = hashedNow
            if job.isActive, featured === job {
                DockProgress.shared.update(job.isVerifyingOnly ? (job.verifyProgress ?? job.progress) : job.progress)
            }
            guard job.status == .running else { continue }
            job.rate = rate
            job.peakRate = max(job.peakRate, rate)
            // Once only checksums remain, the histogram shows the server's hash rate.
            job.history.append(job.isVerifyingOnly ? job.hashRate : rate)
            if job.history.count > 60 { job.history.removeFirst(job.history.count - 60) }
            noteIfDiskBound(job)
        }
    }

    /// Says why a download is slow when the likely cause is the server's disk
    /// (cold files), so it isn't mistaken for a network problem: a minute in,
    /// every connection moving and roughly even, the total under 40 MB/s.
    /// Worded as a likelihood, once per job.
    func noteIfDiskBound(_ job: TransferJob) {
        guard !job.notedDiskBound, case .download = job.kind, !job.isVerifyingOnly, job.history.count >= 60 else { return }
        let average = job.history.reduce(0, +) / Double(job.history.count)
        let rates = job.connectionRates
        guard average > 1, average < 40, rates.count > 1, let low = rates.min(), let high = rates.max(),
              low > 0.1, low >= high * 0.5 else { return }
        job.notedDiskBound = true
        job.note(String(format: "RATE LOOKS SERVER-DISK BOUND · %.0f MB/S WITH ALL %d CONNECTIONS EVEN · COLD FILES READ SLOWER THAN CACHED ONES",
                        average, rates.count))
    }

    // MARK: Engines

    private func download(_ job: TransferJob, from server: ServerConfig) async throws {
        let credential = try server.credential()
        let endpoint = server.endpoint
        let verifier = self.verifier
        let count = max(1, server.connections)
        job.note("CONNECT \(server.host.uppercased()):\(server.port) · \(count) CONNECTIONS")
        let clients = try await withThrowingTaskGroup(of: (Int, SFTPClient).self) { group in
            for i in 0..<count {
                group.addTask {
                    try await Task.sleep(for: .milliseconds(i * 250))
                    let connection = try await SSHConnection.connect(to: endpoint, credential: credential, verifier: verifier)
                    return (i, try await SFTPClient.open(on: connection))
                }
            }
            // If one connection fails, close the ones that opened: leaked sessions
            // would eat into the server's limits and make every retry likelier to fail.
            var opened: [(Int, SFTPClient)] = []
            var firstError: Error?
            while let result = await group.nextResult() {
                switch result {
                case .success(let client): opened.append(client)
                case .failure(let error):
                    if firstError == nil { firstError = error }
                    group.cancelAll()
                }
            }
            if let firstError {
                for (_, client) in opened { await client.connection.close() }
                throw firstError
            }
            return opened.sorted { $0.0 < $1.0 }.map(\.1)
        }
        job.liveConnections = clients.map(\.connection)
        defer {
            job.liveConnections.removeAll()
            for c in clients { Task { await c.connection.close() } }
        }
        let strategy = clients[0].strategy
        job.connections = clients.count
        job.link = "\(clients.count)× · \(strategy.readSize / 1024)K×\(strategy.maxInFlight)"
        // The route (PRD R1.7): Wi-Fi while a wired link is up halves throughput.
        let host = server.host, port = UInt16(clamping: server.port)
        if let path = await Task.detached(operation: { NetworkPath.to(host: host, port: port) }).value {
            job.link += " · \(path.interface.uppercased())"
            // An advisory (PRD R1.7), not a failure: the transfer itself is fine.
            job.routeWarning = path.wifiDespiteWired ? "Wi-Fi (\(path.interface)) while wired is up" : nil
            if path.wifiDespiteWired {
                job.note("✕ ROUTE IS WI-FI (\(path.interface)) WHILE WIRED IS UP · SEE PRD R1.7", failure: true)
            }
        }
        let probe = clients[0]
        job.rttMilliseconds = await Self.roundTrip(probe)
        let rttSampler = Task { [weak job] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let job, let rtt = await Self.roundTrip(probe) else { continue }
                job.rttMilliseconds = rtt
            }
        }
        defer { rttSampler.cancel() }

        var files: [RemoteFile] = []
        var directories: [String] = []
        job.remoteSourceDirectories = []
        for source in job.sources where !job.removedRoots.contains(Self.rootKey(source)) {
            if let path = source.remotePath {
                let tree = try await remoteTree(at: path, using: clients[0], includeHidden: job.includeHidden)
                files += tree.files
                directories += tree.directories
                job.remoteSourceDirectories += tree.sourceDirectories
                for link in tree.skippedSymlinks {
                    job.note("= SKIPPED SYMLINK \(link.uppercased()) · NOT COPIED FROM SERVERS", failure: true)
                }
            }
        }
        job.fileCount = files.count
        job.totalBytes = Int64(files.reduce(0) { $0 + $1.size })
        job.note("LISTED \(files.count) FILE\(files.count == 1 ? "" : "S") · \(TransferJob.bytes(job.totalBytes))")
        let destination = job.destination
        let needed = await Task.detached {
            Self.bytesNeeded(files.map { ($0.relativePath, $0.size) }, in: destination)
        }.value
        guard await waitForSpace(job, needed: needed) else { return }
        job.status = .running
        // Folders first, so empty ones exist at the destination too (PRD R3.1).
        await Task.detached {
            for relative in directories where TransferPlan.isContained(relative) {
                try? FileManager.default.createDirectory(at: destination.appendingPathComponent(relative),
                                                         withIntermediateDirectories: true)
            }
        }.value

        let hasher = RemoteHasher(connection: clients[0].connection)
        var options = TransferOptions()
        options.skipExistingSameSize = true
        options.existsRule = job.existsRule
        options.verify = job.verifies
        if !job.verifies { job.note("VERIFY OFF · FILES ARE SIZE-CHECKED ONLY (SETTINGS › VERIFY FILES)") }
        job.connectionCounters = clients.map { _ in ByteCounter() }
        if job.deleteSources { job.note("MOVE · SOURCES ARE REMOVED ONCE VERIFIED BY SHA256") }
        let ledger = job.verifiedSources
        _ = await BlitRemote.download(files, into: job.destination.path, clients: clients, hasher: hasher,
                                      options: options, counter: job.counter,
                                      connectionCounters: job.connectionCounters) { event in
            ledger.record(event)
            Task { @MainActor in job.handle(event) }
        }
        // Quitting: keep the ledger (saved with the queue) for the next launch.
        if job.deleteSources, !isQuitting { await removeVerifiedSources(job, using: clients[0]) }
    }

    /// For a move from a server: deletes the source files verified so far, then
    /// any source folders left empty.
    private func removeVerifiedSources(_ job: TransferJob, using client: SFTPClient) async {
        let roots = job.sources.compactMap(\.remotePath)
        var folders = Set<RemotePath>()
        var removed = 0
        var interrupted: [VerifiedSources.Remote] = []
        for source in job.verifiedSources.takeRemote() {
            let path = source.path
            guard client.connection.isActive else {
                interrupted.append(source)
                continue
            }
            do {
                // Only if it's still the file that was verified (PRD R2.12).
                let now = try await client.stat(path)
                guard now.size == source.size, now.modificationTime == source.modificationTime else {
                    throw SFTPError.unexpected("changed on the server since it was verified")
                }
                try await client.removeFile(path)
                removed += 1
                if roots.contains(path) { job.removedRoots.insert(String(decoding: path.bytes, as: UTF8.self)) }
                folders.formUnion(Self.folders(of: path.bytes, under: roots.map(\.bytes)).map { RemotePath(bytes: $0) })
            } catch SFTPError.status(let code, _) where code == SFTPStatusCode.noSuchFile.rawValue {
                // Already gone (removed by someone else): nothing to keep.
                removed += 1
            } catch {
                if !client.connection.isActive {
                    interrupted.append(source)
                } else {
                    job.failures.append("source kept: \(path.description): \(error)")
                    job.note("✕ SOURCE KEPT \(path.description) · \(error)".uppercased(), failure: true)
                }
            }
        }
        if !interrupted.isEmpty {
            // Connection lost: keep them in the ledger; the retry removes them.
            job.verifiedSources.add(remote: interrupted)
            job.failures.append("removing \(interrupted.count) verified source file(s) was interrupted; will retry")
        }
        // Every listed source folder, empty ones included, deepest first.
        folders.formUnion(job.remoteSourceDirectories)
        for folder in folders.sorted(by: { $0.bytes.count > $1.bytes.count }) {
            // Fails, harmlessly, if anything is left in it.
            if (try? await client.removeDirectory(folder)) != nil, roots.contains(folder) {
                job.removedRoots.insert(String(decoding: folder.bytes, as: UTF8.self))
            }
        }
        job.removedSources += removed
        noteMoveResult(job, removedNow: removed)
    }

    /// For a move between drives: deletes the source files verified so far,
    /// then any source folders left empty (a lone .DS_Store counts as empty).
    private func removeVerifiedSources(_ job: TransferJob) async {
        let roots = job.sources.compactMap { $0.localURL?.standardizedFileURL.path }
        let sources = job.verifiedSources.takeLocal()
        let destinationPath = job.destination.path
        let links = job.localSourceSymlinks
        let listedFolders = job.localSourceDirectories
        let result = await Task.detached { () -> (removed: Int, failed: [String], gone: [String]) in
            let fm = FileManager.default
            var folders = Set<String>()
            var removed = 0
            var failed: [String] = []
            var gone: [String] = []
            for source in sources {
                let path = source.path
                guard fm.fileExists(atPath: path) else {
                    removed += 1   // already gone
                    continue
                }
                do {
                    // Only if it's still the regular file that was verified: a file
                    // rewritten since (or replaced by a folder) is kept.
                    let now = try fm.attributesOfItem(atPath: path)
                    guard now[.type] as? FileAttributeType == .typeRegular,
                          (now[.size] as? NSNumber)?.uint64Value == source.size,
                          source.modificationTime == nil || now[.modificationDate] as? Date == source.modificationTime else {
                        failed.append("\(path): changed since it was verified")
                        continue
                    }
                    try fm.removeItem(atPath: path)
                    removed += 1
                    if roots.contains(path) { gone.append(path) }
                    for folder in Self.folders(of: Array(path.utf8), under: roots.map { Array($0.utf8) }) {
                        folders.insert(String(decoding: folder, as: UTF8.self))
                    }
                } catch {
                    failed.append("\(path): \(error.localizedDescription)")
                }
            }
            // Symlinks that now exist at the destination with the same target.
            for link in links {
                let copied = try? fm.destinationOfSymbolicLink(atPath: destinationPath + "/" + link.relativePath)
                if copied == link.target, (try? fm.removeItem(atPath: link.source)) != nil, roots.contains(link.source) {
                    gone.append(link.source)
                }
            }
            folders.formUnion(listedFolders)
            for folder in folders.sorted(by: { $0.utf8.count > $1.utf8.count }) {
                guard let contents = try? fm.contentsOfDirectory(atPath: folder),
                      contents.allSatisfy({ $0 == ".DS_Store" }) else { continue }
                if (try? fm.removeItem(atPath: folder)) != nil, roots.contains(folder) { gone.append(folder) }
            }
            return (removed, failed, gone)
        }.value
        job.removedRoots.formUnion(result.gone)
        for failure in result.failed {
            job.failures.append("source kept: \(failure)")
            job.note("✕ SOURCE KEPT \(failure)".uppercased(), failure: true)
        }
        job.removedSources += result.removed
        noteMoveResult(job, removedNow: result.removed)
    }

    private func noteMoveResult(_ job: TransferJob, removedNow: Int) {
        if removedNow > 0 { job.note("✓ MOVED · REMOVED \(removedNow) SOURCE FILE\(removedNow == 1 ? "" : "S")") }
        let kept = job.fileCount - job.removedSources - job.failures.count
        if kept > 0 {
            job.note("= \(kept) SOURCE FILE\(kept == 1 ? "" : "S") KEPT · ALREADY THERE OR NOT HASH-VERIFIED", failure: true)
        }
    }

    /// The folders between `path` and the source root it's under (the root
    /// included), deepest first. Empty when `path` is itself a root.
    nonisolated static func folders(of path: [UInt8], under roots: [[UInt8]]) -> [[UInt8]] {
        let slash = UInt8(ascii: "/")
        guard let root = roots.first(where: { path.count > $0.count && path.starts(with: $0 + [slash]) }) else { return [] }
        var result: [[UInt8]] = []
        var current = path
        while let cut = current.lastIndex(of: slash), cut >= root.count {
            current = Array(current[..<cut])
            result.append(current)
        }
        return result
    }

    private func copy(_ job: TransferJob) async throws {
        var files: [LocalFile] = []
        var directories: [String] = []
        job.localSourceDirectories = []
        job.localSourceSymlinks = []
        for source in job.sources where !job.removedRoots.contains(Self.rootKey(source)) {
            guard let url = source.localURL else { continue }
            // Off the main actor: walking a big tree over SMB would beachball the app.
            let tree = try await Task.detached { try localTree(at: url.path) }.value
            files += tree.files
            directories += tree.directories
            job.localSourceDirectories += tree.sourceDirectories
            job.localSourceSymlinks += tree.symlinks
            for item in tree.skipped {
                job.note("= SKIPPED \(item.relativePath.uppercased()) · \(item.reason.uppercased())", failure: true)
            }
        }
        job.fileCount = files.count
        job.totalBytes = Int64(files.reduce(0) { $0 + $1.size })
        job.note("LISTED \(files.count) FILE\(files.count == 1 ? "" : "S") · \(TransferJob.bytes(job.totalBytes))")
        let destination = job.destination
        let copyNeeded = await Task.detached { () -> UInt64 in
            let destinationVolume = Self.volumeID(destination)
            let copied = files.filter { file in
                // Same APFS volume: a clone, which takes no new space.
                guard let destinationVolume, let volume = Self.volumeID(URL(fileURLWithPath: file.path)) else { return true }
                return !volume.isEqual(destinationVolume)
            }
            return Self.bytesNeeded(copied.map { ($0.relativePath, $0.size) }, in: destination)
        }.value
        guard await waitForSpace(job, needed: copyNeeded) else { return }

        let mount = MountInfo.containing(job.destination.path)   // the mount table: no waiting on a hung share
        if let mount, mount.isSMB {
            let host = mount.source.split(separator: "@").last?.split(separator: "/").first
                .map { String($0).replacingOccurrences(of: "._smb._tcp", with: "") }
            // Off the main actor: resolving a .local NAS name blocks on mDNS.
            if let host, let path = await Task.detached(operation: { NetworkPath.to(host: host) }).value {
                job.link = "SMB · \(path.interface.uppercased())"
                // An advisory (PRD R1.7), not a failure: the copy itself is fine.
                job.routeWarning = path.wifiDespiteWired ? "Wi-Fi (\(path.interface)) while wired is up" : nil
                if path.wifiDespiteWired {
                    job.note("✕ ROUTE IS WI-FI (\(path.interface)) WHILE WIRED IS UP · SEE PRD R1.7", failure: true)
                }
            } else {
                job.link = "SMB"
            }
        } else {
            job.link = "LOCAL"
        }
        job.connections = 2

        // Verify on the NAS itself when this share has a NAS login (PRD R1.6, R4.2).
        var nas: NASVerifier?
        var nasConnection: SSHConnection?
        if job.verifies, let mount, let login = servers.nasLogin(forMount: mount.mountPoint),
           let root = login.nasRoot, login.hasCredential {
            do {
                let connection = try await SSHConnection.connect(to: login.endpoint, credential: try login.credential(),
                                                                 verifier: verifier)
                nasConnection = connection
                job.liveConnections = [connection]
                nas = NASVerifier(connection: connection, mountPoint: mount.mountPoint, nasRoot: root)
                job.nasVerified = true
                job.note("NAS \(login.host.uppercased()) · VERIFYING ON \(root.uppercased())")
            } catch {
                job.note("✕ NAS LOGIN FAILED · FALLING BACK TO READ-BACK · \(error)".uppercased(), failure: true)
            }
        }
        defer {
            job.liveConnections.removeAll()
            if let nasConnection { Task { await nasConnection.close() } }
        }

        job.status = .running
        var options = CopyOptions()
        options.skipExistingSameSize = true
        options.existsRule = job.existsRule
        options.verify = job.verifies
        // A move removes each source only once its copy is verified by SHA-256,
        // and a clone isn't hashed: a move never clones. (Moves within one disk
        // are renames and don't come here; a file only in the cloud does, and
        // its provider can download it again in the meantime, which let it
        // clone and stay behind.)
        options.allowClone = !job.deleteSources
        if !job.verifies { job.note("VERIFY OFF · FILES ARE SIZE-CHECKED ONLY (SETTINGS › VERIFY FILES)") }
        let stopFlag = job.stopFlag
        options.shouldStop = { stopFlag.isSet }
        job.connectionCounters = (0..<options.concurrentFiles).map { _ in ByteCounter() }
        if job.deleteSources { job.note("MOVE · SOURCES ARE REMOVED ONCE VERIFIED BY SHA256") }
        let ledger = job.verifiedSources
        _ = try await BlitLocal.copy(files, into: job.destination.path, nas: nas, options: options, counter: job.counter,
                                     streamCounters: job.connectionCounters) { event in
            ledger.record(event)
            Task { @MainActor in job.handle(event) }
        }
        // Empty folders and symlinks too (PRD R3.1).
        let links = job.localSourceSymlinks
        let structureProblems = await Task.detached {
            recreateStructure(directories: directories, symlinks: links, into: destination.path)
        }.value
        for problem in structureProblems {
            job.failures.append(problem)
            job.note("✕ \(problem)".uppercased(), failure: true)
        }
        if !links.isEmpty, structureProblems.isEmpty {
            job.note("✓ RECREATED \(links.count) SYMLINK\(links.count == 1 ? "" : "S")")
        }
        if job.deleteSources, !isQuitting { await removeVerifiedSources(job) }
    }
}

extension TransferJob {
    private func sourceDescription(_ path: String) -> String {
        if case .download(let server) = kind { return "\(server.username)@\(server.host):\(path)" }
        return path
    }

    private func record(source: String, relativePath: String, size: UInt64, sha256: String?, verification: String,
                        failed: String? = nil, cached: Bool? = nil) {
        TransferLog.append(TransferRecord(time: Date(), source: sourceDescription(source),
                                          destination: destination.appendingPathComponent(relativePath).path,
                                          size: size, sha256: sha256, verification: verification,
                                          result: failed == nil ? "ok" : "failed", detail: failed, cached: cached))
    }

    func handle(_ event: TransferEvent) {
        // Files cut off by a pause, a cancel or quitting Blit aren't failures.
        if stopRequest != nil || isShuttingDown, case .fileFailed = event { return }
        if case .fileFinished(let f, _) = event, completedPaths.contains(f.relativePath) { return }
        if case .fileHashProgress(let f, let bytes) = event {
            // Late progress for a file that's already done is dropped.
            guard !completedPaths.contains(f.relativePath), !failures.contains(where: { $0.hasPrefix(f.relativePath + ":") }) else { return }
            let previous = hashed[f.relativePath] ?? 0
            if bytes > previous { hashedTotal += bytes - previous }
            hashed[f.relativePath] = bytes
            hashSizes[f.relativePath] = f.size
            return
        }
        if case .fileFinished(let f, let v) = event {
            let (hash, method): (String?, String) = switch v {
            case .sha256(let h, _): (h, "server-sha256")
            case .sizeOnly: (nil, "size-only")
            case .skipped: (nil, "verify-off")
            case .alreadyPresent: (nil, "already-present")
            case .alreadyPresentVerified(let h): (h, "present-sha256")
            }
            var cached: Bool?
            if case .sha256(_, let hit) = v {
                cached = hit
                if hit { hashCacheHits += 1 }
            }
            record(source: f.path.description, relativePath: f.relativePath, size: f.size, sha256: hash, verification: method,
                   cached: cached)
            outcomes[f.relativePath] = method
            inFlight.remove(f.relativePath)
        } else if case .fileFailed(let f, let reason) = event {
            record(source: f.path.description, relativePath: f.relativePath, size: f.size, sha256: nil, verification: "none", failed: reason)
            inFlight.remove(f.relativePath)
        }
        switch event {
        case .fileResumed(let f, let bytes):
            // Bytes from an earlier attempt of this job are already in the counter.
            if attempt == 0 { resumedBytes += Int64(bytes) }
            note("RESUME \(f.relativePath.uppercased()) · \(Self.bytes(Int64(bytes))) ON DISK")
        case .fileStarted(let f):
            inFlight.insert(f.relativePath)
            note("GET \(f.relativePath.uppercased())")
        case .fileDownloaded(let f):
            inFlight.remove(f.relativePath)
            verifying[f.relativePath] = Date()
            hashSizes[f.relativePath] = f.size
            note("DOWNLOADED \(f.relativePath.uppercased()) · VERIFYING")
        case .fileHashProgress:
            break
        case .fileFinished(let f, let v):
            verifying[f.relativePath] = nil
            hashed[f.relativePath] = nil
            hashSizes[f.relativePath] = nil
            guard completedPaths.insert(f.relativePath).inserted else { return }
            filesFinished += 1
            switch v {
            case .sha256(let hash, let cached):
                filesVerified += 1
                note("✓ SHA256 \(hash.prefix(8).uppercased())… VERIFIED · \(f.relativePath.uppercased())\(cached ? " · SERVER CACHE" : "")")
            case .sizeOnly(let why):
                sizeOnlyCount += 1
                note("= SIZE ONLY · NOT HASH-VERIFIED · \(f.relativePath.uppercased()) · \(why.uppercased())", failure: true)
            case .skipped:
                unverifiedCount += 1
                note("= \(f.relativePath.uppercased()) · SIZE CHECKED · VERIFY OFF")
            case .alreadyPresent:
                filesAlreadyPresent += 1
                presentBytes += Int64(f.size)
                note("= ALREADY PRESENT · \(f.relativePath.uppercased())")
            case .alreadyPresentVerified(let hash):
                filesAlreadyPresent += 1
                filesVerified += 1
                presentBytes += Int64(f.size)
                note("= ALREADY PRESENT · SHA256 \(hash.prefix(8).uppercased())… MATCHES · \(f.relativePath.uppercased())")
            }
        case .fileFailed(let f, let reason):
            verifying[f.relativePath] = nil
            hashed[f.relativePath] = nil
            hashSizes[f.relativePath] = nil
            recordFailure(f.relativePath, reason)
        }
    }

    func handle(_ event: CopyEvent) {
        if stopRequest != nil || isShuttingDown, case .fileFailed = event { return }
        if case .fileFinished(let f, _) = event, completedPaths.contains(f.relativePath) { return }
        if case .fileHashProgress(let f, let bytes) = event {
            guard verifying[f.relativePath] != nil else { return }   // late, after the file finished
            let previous = hashed[f.relativePath] ?? 0
            if bytes > previous { hashedTotal += bytes - previous }
            hashed[f.relativePath] = bytes
            return
        }
        if case .fileFinished(let f, let v) = event {
            let (hash, method): (String?, String) = switch v {
            case .nas(let h): (h, "nas-sha256")
            case .readBack(let h, _): (h, "read-back")
            case .cloned: (nil, "cloned")
            case .skipped: (nil, "verify-off")
            case .alreadyPresent: (nil, "already-present")
            case .alreadyPresentVerified(let h): (h, "present-sha256")
            }
            record(source: f.path, relativePath: f.relativePath, size: f.size, sha256: hash, verification: method)
            outcomes[f.relativePath] = method
            inFlight.remove(f.relativePath)
        } else if case .fileFailed(let f, let reason) = event {
            record(source: f.path, relativePath: f.relativePath, size: f.size, sha256: nil, verification: "none", failed: reason)
            inFlight.remove(f.relativePath)
        }
        switch event {
        case .fileStarted(let f):
            inFlight.insert(f.relativePath)
            note("COPY \(f.relativePath.uppercased())")
        case .fileCopied(let f):
            inFlight.remove(f.relativePath)
            verifying[f.relativePath] = Date()
            hashSizes[f.relativePath] = f.size
            note("COPIED \(f.relativePath.uppercased()) · VERIFYING")
        case .fileHashProgress:
            break
        case .fileFinished(let f, let v):
            verifying[f.relativePath] = nil
            hashed[f.relativePath] = nil
            hashSizes[f.relativePath] = nil
            guard completedPaths.insert(f.relativePath).inserted else { return }
            filesFinished += 1
            switch v {
            case .nas(let hash):
                filesVerified += 1
                note("✓ SHA256 \(hash.prefix(8).uppercased())… VERIFIED ON NAS · \(f.relativePath.uppercased())")
            case .readBack(let hash, let reason):
                filesVerified += 1
                if reason != nil { readBackCount += 1 }
                note("✓ SHA256 \(hash.prefix(8).uppercased())… READ-BACK · \(f.relativePath.uppercased())\(reason.map { " · \($0.uppercased())" } ?? "")")
            case .cloned: note("✓ CLONED · \(f.relativePath.uppercased())")
            case .skipped:
                unverifiedCount += 1
                note("= \(f.relativePath.uppercased()) · SIZE CHECKED · VERIFY OFF")
            case .alreadyPresent:
                filesAlreadyPresent += 1
                presentBytes += Int64(f.size)
                note("= ALREADY PRESENT · \(f.relativePath.uppercased())")
            case .alreadyPresentVerified(let hash):
                filesAlreadyPresent += 1
                filesVerified += 1
                presentBytes += Int64(f.size)
                note("= ALREADY PRESENT · SHA256 \(hash.prefix(8).uppercased())… MATCHES · \(f.relativePath.uppercased())")
            }
        case .fileFailed(let f, let reason):
            verifying[f.relativePath] = nil
            hashed[f.relativePath] = nil
            hashSizes[f.relativePath] = nil
            recordFailure(f.relativePath, reason)
        }
    }

    /// Records a file's failure. A file whose bytes keep failing verification
    /// (SHA-256 mismatch, changed while transferring) stops being retried after
    /// a few attempts, even though each attempt moved bytes (PRD R4.3: one
    /// automatic re-download, not an endless loop).
    private func recordFailure(_ path: String, _ reason: String) {
        let r = reason.lowercased()
        var text = "\(path): \(reason)"
        if r.contains("mismatch") || r.contains("changed since") || r.contains("changed while") || r.contains("changed on the server") {
            let count = (verificationFailureCounts[path] ?? 0) + 1
            verificationFailureCounts[path] = count
            let limit = r.contains("mismatch") ? 2 : 3
            if count >= limit { text = "\(path): gave up after \(count) attempts: \(reason)" }
        }
        failures.append(text)
        note("✕ \(text.uppercased())", failure: true)
    }

    /// A duration for ETAs: "04:12", "5:12:03", or "~2 d 4 h" beyond a day.
    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s >= 86_400 { return "~\(s / 86_400) d \(s % 86_400 / 3600) h" }
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) }
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func bytes(_ n: Int64) -> String {
        n == 0 ? "0 B" : n.formatted(.byteCount(style: .file)).uppercased()
    }
}
