// Transfers started by drag and drop (PRD R2.10): a queue run one job at a
// time, using BlitKit's parallel verified download (server → local) or
// verified copy (local → local, cloning within one APFS volume).

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

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .blitLocations)
    }
}

/// Source files whose copies were verified by SHA-256, so a move may remove
/// them. Filled from the engines' event callbacks, which run off the main actor.
final class VerifiedSources: @unchecked Sendable {
    private let lock = NSLock()
    private var local: [String] = []
    private var remote: [RemotePath] = []

    func record(_ event: TransferEvent) {
        guard case .fileFinished(let file, .sha256) = event else { return }
        lock.withLock { remote.append(file.path) }
    }

    func record(_ event: CopyEvent) {
        switch event {
        case .fileFinished(let file, .nas), .fileFinished(let file, .readBack):
            lock.withLock { local.append(file.path) }
        default: break
        }
    }

    /// Takes the recorded paths, leaving the ledger empty.
    func takeLocal() -> [String] { lock.withLock { defer { local = [] }; return local } }
    func takeRemote() -> [RemotePath] { lock.withLock { defer { remote = [] }; return remote } }
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
    }

    let id = UUID()
    let kind: Kind
    let sources: [BrowseLocation]
    let destination: URL
    let title: String
    let destinationName: String

    var status: Status = .queued
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

    /// All bytes are in and files are waiting on their checksums.
    var isVerifyingOnly: Bool { isActive && !verifying.isEmpty && transferred >= totalBytes }

    /// Files the server is hashing, with how far along each is.
    var hashing: [(name: String, fraction: Double)] {
        hashed.keys.sorted().map { name in
            (name, min(1, Double(hashed[name] ?? 0) / Double(max(hashSizes[name] ?? 1, 1))))
        }
    }

    /// How far verification of the downloaded files has got, where the server
    /// reports progress.
    var verifyProgress: Double? {
        let names = verifying.keys.filter { hashSizes[$0] != nil }
        let total = names.reduce(UInt64(0)) { $0 + (hashSizes[$1] ?? 0) }
        guard total > 0 else { return nil }
        let done = names.reduce(UInt64(0)) { $0 + min(hashed[$1] ?? 0, hashSizes[$1] ?? 0) }
        return Double(done) / Double(total)
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
    var isActive: Bool {
        switch status {
        case .preparing, .running, .waiting: true
        default: false
        }
    }
    /// How files are verified, for the HUD.
    var verificationMethod: String {
        if case .download = kind { return "SERVER SHA256" }
        return nasVerified ? "NAS SHA256" : "READ-BACK"
    }
    var nasVerified = false
    /// Include hidden files when walking folders (captured at drop time).
    var includeHidden = false
    /// A move (Cut, then Paste on another drive or from a server): each source
    /// file is removed once its copy is verified by SHA-256. Anything not
    /// verified that way stays where it was.
    var deleteSources = false
    @ObservationIgnored let verifiedSources = VerifiedSources()
    var removedSources = 0

    func note(_ text: String, failure: Bool = false) {
        #if DEBUG
        LayoutLog.write("note \(text.prefix(60))")
        #endif
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
    @ObservationIgnored private var running = false
    /// Connections held by the running job, closed if Blit quits mid-transfer.
    @ObservationIgnored private var liveConnections: [SSHConnection] = []
    @ObservationIgnored private var isQuitting = false
    @ObservationIgnored private var notificationProblemReported = false
    /// Held while transferring so the Mac doesn't idle-sleep (PRD R5.6).
    @ObservationIgnored private var keepAwake: NSObjectProtocol?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?

    var hasActiveWork: Bool { jobs.contains { $0.isActive } }

    /// Called when Blit is quitting mid-transfer: keeps the queue (including the
    /// running job) saved for next launch, then closes connections so the
    /// engines stop promptly. Resume data is already on disk.
    func prepareForQuit() async {
        saveQueue()
        isQuitting = true
        let connections = liveConnections
        liveConnections.removeAll()
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

    private func expandForTransfer() {
        let wanted = UserDefaults.standard.object(forKey: "expandHUDOnTransfer") as? Bool ?? true
        if !jobs.contains(where: { $0.isActive && !$0.isOperation }) { collapsedThisBatch = false }
        if wanted, !collapsedThisBatch { isExpanded = true }
    }
    /// Files handed to Blit from Finder (Services › Send to Blit…), waiting
    /// for the user to pick a destination.
    var pendingExternalFiles: [URL] = []

    /// The job the strip shows: the most recently started active one (so a
    /// delete shows over a long download while it runs), else the most recent.
    var featured: TransferJob? {
        jobs.filter(\.isActive).max { ($0.startedAt ?? .distantPast) < ($1.startedAt ?? .distantPast) }
            ?? jobs.last(where: { $0.status != .queued }) ?? jobs.first
    }

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
        guard job.failures.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            jobs.removeAll { $0 === job }
            if jobs.isEmpty { isExpanded = false }
        }
    }
    var queuedCount: Int { jobs.filter { $0.status == .queued }.count }

    func dismissFinished() {
        jobs.removeAll { !$0.isActive && $0.status != .queued }
        if jobs.isEmpty { isExpanded = false }
    }

    /// Queues a transfer of `sources` into `destination`. Returns a message
    /// if it can't be done.
    func enqueue(_ sources: [BrowseLocation], to destination: BrowseLocation, destinationName: String,
                 includeHidden: Bool = false, move: Bool = false) -> String? {
        guard let folder = destination.localURL else {
            return "Uploading to a server isn't supported yet. Drop onto a local folder, drive or NAS share."
        }
        let sources = sources.uniqued()
        let remote = sources.filter { $0.serverID != nil }
        let local = sources.compactMap(\.localURL)
        if Set(remote.compactMap(\.serverID)).count > 1 { return "Drag from one server at a time." }
        let target = folder.standardizedFileURL.path
        if local.contains(where: { let p = $0.standardizedFileURL.path; return target == p || target.hasPrefix(p + "/") }) {
            return "Can't copy a folder into itself."
        }
        if let id = remote.first?.serverID {
            guard let server = servers.server(id) else { return "That server no longer exists." }
            let job = TransferJob(kind: .download(server), sources: remote, destination: folder,
                                  title: Self.title(remote.map(\.lastComponent)), destinationName: destinationName)
            job.includeHidden = includeHidden
            job.deleteSources = move
            jobs.append(job)
        }
        if !local.isEmpty {
            let job = TransferJob(kind: .copy, sources: local.map { .local($0) }, destination: folder,
                                  title: Self.title(local.map(\.lastPathComponent)), destinationName: destinationName)
            job.deleteSources = move
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
    }

    private static var queueURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Blit/queue.json")
    }

    /// Saves unfinished jobs, so a quit or restart doesn't lose them.
    private func saveQueue() {
        // While quitting, the running job fails as its connections close; keep it saved.
        guard !isQuitting else { return }
        let pending = jobs.filter { !$0.isOperation && ($0.status == .queued || $0.isActive) }.map { job -> SavedJob in
            var serverID: UUID?
            if case .download(let server) = job.kind { serverID = server.id }
            return SavedJob(serverID: serverID, sources: job.sources, destination: job.destination, title: job.title,
                            destinationName: job.destinationName, includeHidden: job.includeHidden,
                            deleteSources: job.deleteSources)
        }
        let url = Self.queueURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(pending) { try? data.write(to: url, options: .atomic) }
    }

    /// Brings back jobs that hadn't finished when Blit last quit. Downloads resume
    /// from their .blitpart files; files already complete are skipped.
    func restoreQueue() {
        guard jobs.isEmpty, let data = try? Data(contentsOf: Self.queueURL),
              let saved = try? JSONDecoder().decode([SavedJob].self, from: data), !saved.isEmpty else { return }
        for s in saved {
            let kind: TransferJob.Kind
            if let id = s.serverID {
                guard let server = servers.server(id) else { continue }
                kind = .download(server)
            } else {
                kind = .copy
            }
            let job = TransferJob(kind: kind, sources: s.sources, destination: s.destination, title: s.title,
                                  destinationName: s.destinationName)
            job.includeHidden = s.includeHidden
            job.deleteSources = s.deleteSources ?? false
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
        guard !isQuitting else { return }
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
        let content = UNMutableNotificationContent()
        let size = job.totalBytes.formatted(.byteCount(style: .file))
        if job.failures.isEmpty {
            content.title = "\(job.title) → \(job.destinationName)"
            var body = "\(job.filesVerified) of \(job.fileCount) files verified · \(size)"
            if job.allAlreadyPresent { body = "All \(job.fileCount) already there · \(size)" }
            else if job.filesAlreadyPresent > 0 { body += " · \(job.filesAlreadyPresent) already there" }
            content.body = body
        } else {
            content.title = "\(job.failures.count) problem\(job.failures.count == 1 ? "" : "s"): \(job.title)"
            content.body = job.failures.prefix(3).joined(separator: "\n")
            content.sound = .default
        }
        try? await center.add(UNNotificationRequest(identifier: job.id.uuidString, content: content, trigger: nil))
    }

    private static func title(_ names: [String]) -> String {
        guard let first = names.first else { return "" }
        return names.count == 1 ? first : "\(first) +\(names.count - 1)"
    }

    private func runNext() {
        guard !running, let job = jobs.first(where: { $0.status == .queued }) else { return }
        running = true
        Task {
            await run(job)
            running = false
            saveQueue()
            if !isQuitting, !jobs.contains(where: { !$0.isOperation && ($0.status == .queued || $0.isActive) }) {
                DockProgress.shared.finish(verified: job.status == .finished && job.failures.isEmpty)
            }
            onFinished?(job)
            await notify(job)
            runNext()
        }
    }

    /// Failure reasons a retry can't fix (from BlitKit's messages).
    private static let permanentMarkers = [
        "already exists", "same local name", "changed since it was listed", "changed on the server",
        "shorter than listed", "no such file", "permission denied", "status 2", "status 3",
        "server refused", "authentication failed", "host key", "no password", "no longer exists",
    ]

    static func isRetryable(_ reason: String) -> Bool {
        let r = reason.lowercased()
        return !permanentMarkers.contains { r.contains($0) }
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
        if keepAwake == nil {
            keepAwake = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled],
                                                              reason: "Blit is transferring files")
        }
        defer {
            if let activity = keepAwake { ProcessInfo.processInfo.endActivity(activity) }
            keepAwake = nil
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
            if isQuitting { break }
            if fatal == nil, job.failures.isEmpty {
                job.status = .finished
                break
            }
            let reasons = fatal.map { [$0] } ?? job.failures
            // A drive or share that went away turns into "no such file"-style errors;
            // that's worth waiting for, whatever the message says (PRD R1.4).
            let missing = missingVolumes(job)
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
            job.status = .waiting(until: Date().addingTimeInterval(TimeInterval(delay)), reason: reason)
            try? await Task.sleep(for: .seconds(delay))
            await waitForNetwork(job)
            await waitForVolumes(job)
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

    /// "disconnected: no data from the server for 60 s" → "NO DATA FROM THE SERVER FOR 60 S"
    private static func shortReason(_ reason: String) -> String {
        let trimmed = reason.split(separator: ":", maxSplits: 1).last.map(String.init) ?? reason
        return String(trimmed.trimmingCharacters(in: .whitespaces).prefix(80))
    }

    /// Waits until macOS reports a usable network path.
    private func waitForNetwork(_ job: TransferJob) async {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
        }
        let monitor = NWPathMonitor()
        let once = Once()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            monitor.pathUpdateHandler = { path in
                if path.status == .satisfied, once.claim() { continuation.resume() }
            }
            monitor.start(queue: .global(qos: .utility))
        }
        monitor.cancel()
    }

    /// Names of the job's destination and local source folders that are missing
    /// (an SSD unplugged, a NAS share unmounted).
    private func missingVolumes(_ job: TransferJob) -> [String] {
        let fm = FileManager.default
        var missing: [String] = []
        if !fm.fileExists(atPath: job.destination.path) { missing.append(job.destinationName) }
        for url in job.sources.compactMap(\.localURL) where !fm.fileExists(atPath: url.path) {
            let volume = url.pathComponents.count > 2 && url.pathComponents[1] == "Volumes" ? url.pathComponents[2] : url.lastPathComponent
            if !missing.contains(volume) { missing.append(volume) }
        }
        return missing
    }

    /// Waits (up to an hour) for missing drives or shares to come back.
    private func waitForVolumes(_ job: TransferJob) async {
        var noted = Set<String>()
        for _ in 0..<720 {
            let missing = missingVolumes(job)
            if missing.isEmpty || isQuitting { return }
            for name in missing where noted.insert(name).inserted {
                job.note("WAITING FOR \(name.uppercased()) TO COME BACK", failure: true)
            }
            try? await Task.sleep(for: .seconds(5))
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
            #if DEBUG
            LayoutLog.write("sample rate \(String(format: "%.1f", rate)) conns \(job.connectionRates.map { String(format: "%.1f", $0) }.joined(separator: " "))")
            #endif
            let hashedNow = job.hashedTotal
            job.hashRate = Double(hashedNow - min(lastHashed, hashedNow)) / seconds / 1e6
            lastHashed = hashedNow
            if job.isActive { DockProgress.shared.update(job.isVerifyingOnly ? (job.verifyProgress ?? job.progress) : job.progress) }
            guard job.status == .running else { continue }
            job.rate = rate
            job.peakRate = max(job.peakRate, rate)
            // Once only checksums remain, the histogram shows the server's hash rate.
            job.history.append(job.isVerifyingOnly ? job.hashRate : rate)
            if job.history.count > 60 { job.history.removeFirst(job.history.count - 60) }
        }
    }

    // MARK: Engines

    private func download(_ job: TransferJob, from server: ServerConfig) async throws {
        guard let password = Keychain.password(for: server) else { throw ConnectionError.noPassword }
        let credential = SSHCredential.password(password)
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
            var opened: [(Int, SFTPClient)] = []
            for try await c in group { opened.append(c) }
            return opened.sorted { $0.0 < $1.0 }.map(\.1)
        }
        liveConnections = clients.map(\.connection)
        defer {
            liveConnections.removeAll()
            for c in clients { Task { await c.connection.close() } }
        }
        let strategy = clients[0].strategy
        job.connections = clients.count
        job.link = "\(clients.count)× · \(strategy.readSize / 1024)K×\(strategy.maxInFlight)"

        var files: [RemoteFile] = []
        for source in job.sources {
            if let path = source.remotePath {
                files += try await remoteFiles(at: path, using: clients[0], includeHidden: job.includeHidden)
            }
        }
        job.fileCount = files.count
        job.totalBytes = Int64(files.reduce(0) { $0 + $1.size })
        job.note("LISTED \(files.count) FILE\(files.count == 1 ? "" : "S") · \(TransferJob.bytes(job.totalBytes))")
        job.status = .running

        let hasher = RemoteHasher(connection: clients[0].connection)
        var options = TransferOptions()
        options.skipExistingSameSize = true
        job.connectionCounters = clients.map { _ in ByteCounter() }
        if job.deleteSources { job.note("MOVE · SOURCES ARE REMOVED ONCE VERIFIED BY SHA256") }
        let ledger = job.verifiedSources
        _ = await BlitRemote.download(files, into: job.destination.path, clients: clients, hasher: hasher,
                                      options: options, counter: job.counter,
                                      connectionCounters: job.connectionCounters) { event in
            ledger.record(event)
            Task { @MainActor in job.handle(event) }
        }
        if job.deleteSources { await removeVerifiedSources(job, using: clients[0]) }
    }

    /// For a move from a server: deletes the source files verified so far, then
    /// any source folders left empty.
    private func removeVerifiedSources(_ job: TransferJob, using client: SFTPClient) async {
        let roots = job.sources.compactMap(\.remotePath)
        var folders = Set<RemotePath>()
        var removed = 0
        for path in job.verifiedSources.takeRemote() {
            do {
                try await client.removeFile(path)
                removed += 1
                folders.formUnion(Self.folders(of: path.bytes, under: roots.map(\.bytes)).map { RemotePath(bytes: $0) })
            } catch {
                job.note("✕ KEPT \(path.description.uppercased()) · \(error)".uppercased(), failure: true)
            }
        }
        for folder in folders.sorted(by: { $0.bytes.count > $1.bytes.count }) {
            try? await client.removeDirectory(folder)    // fails, harmlessly, if anything is left in it
        }
        job.removedSources += removed
        noteMoveResult(job, removedNow: removed)
    }

    /// For a move between drives: deletes the source files verified so far,
    /// then any source folders left empty (a lone .DS_Store counts as empty).
    private func removeVerifiedSources(_ job: TransferJob) async {
        let roots = job.sources.compactMap { $0.localURL?.standardizedFileURL.path }
        let paths = job.verifiedSources.takeLocal()
        let result = await Task.detached { () -> (removed: Int, failed: [String]) in
            let fm = FileManager.default
            var folders = Set<String>()
            var removed = 0
            var failed: [String] = []
            for path in paths {
                do {
                    try fm.removeItem(atPath: path)
                    removed += 1
                    for folder in Self.folders(of: Array(path.utf8), under: roots.map { Array($0.utf8) }) {
                        folders.insert(String(decoding: folder, as: UTF8.self))
                    }
                } catch {
                    failed.append("\(path): \(error.localizedDescription)")
                }
            }
            for folder in folders.sorted(by: { $0.utf8.count > $1.utf8.count }) {
                guard let contents = try? fm.contentsOfDirectory(atPath: folder),
                      contents.allSatisfy({ $0 == ".DS_Store" }) else { continue }
                try? fm.removeItem(atPath: folder)
            }
            return (removed, failed)
        }.value
        for failure in result.failed { job.note("✕ KEPT \(failure)".uppercased(), failure: true) }
        job.removedSources += result.removed
        noteMoveResult(job, removedNow: result.removed)
    }

    private func noteMoveResult(_ job: TransferJob, removedNow: Int) {
        if removedNow > 0 { job.note("✓ MOVED · REMOVED \(removedNow) SOURCE FILE\(removedNow == 1 ? "" : "S")") }
        let kept = job.fileCount - job.removedSources
        if kept > 0, job.failures.isEmpty {
            job.note("= \(kept) SOURCE FILE\(kept == 1 ? "" : "S") KEPT · NOT VERIFIED BY SHA256 IN THIS MOVE", failure: true)
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
        for source in job.sources {
            if let url = source.localURL { files += try localFiles(at: url.path) }
        }
        job.fileCount = files.count
        job.totalBytes = Int64(files.reduce(0) { $0 + $1.size })
        job.note("LISTED \(files.count) FILE\(files.count == 1 ? "" : "S") · \(TransferJob.bytes(job.totalBytes))")

        if let mount = MountInfo.of(job.destination.path), mount.isSMB {
            let host = mount.source.split(separator: "@").last?.split(separator: "/").first
                .map { String($0).replacingOccurrences(of: "._smb._tcp", with: "") }
            if let host, let path = NetworkPath.to(host: host) {
                job.link = "SMB · \(path.interface.uppercased())"
                if path.wifiDespiteWired {
                    job.note("✕ ROUTE IS WI-FI (\(path.interface)) WHILE WIRED IS UP · SEE PRD R1.7", failure: true)
                    job.failures.append("Copy is going over Wi-Fi while a wired link is up")
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
        if let mount = MountInfo.of(job.destination.path), let login = servers.nasLogin(forMount: mount.mountPoint),
           let root = login.nasRoot, let password = Keychain.password(for: login) {
            do {
                let connection = try await SSHConnection.connect(to: login.endpoint, credential: .password(password),
                                                                 verifier: verifier)
                nasConnection = connection
                liveConnections = [connection]
                nas = NASVerifier(connection: connection, mountPoint: mount.mountPoint, nasRoot: root)
                job.nasVerified = true
                job.note("NAS \(login.host.uppercased()) · VERIFYING ON \(root.uppercased())")
            } catch {
                job.note("✕ NAS LOGIN FAILED · FALLING BACK TO READ-BACK · \(error)".uppercased(), failure: true)
            }
        }
        defer {
            liveConnections.removeAll()
            if let nasConnection { Task { await nasConnection.close() } }
        }

        job.status = .running
        var options = CopyOptions()
        options.skipExistingSameSize = true
        job.connectionCounters = (0..<options.concurrentFiles).map { _ in ByteCounter() }
        if job.deleteSources { job.note("MOVE · SOURCES ARE REMOVED ONCE VERIFIED BY SHA256") }
        let ledger = job.verifiedSources
        _ = try await BlitLocal.copy(files, into: job.destination.path, nas: nas, options: options, counter: job.counter,
                                     streamCounters: job.connectionCounters) { event in
            ledger.record(event)
            Task { @MainActor in job.handle(event) }
        }
        if job.deleteSources { await removeVerifiedSources(job) }
    }
}

extension TransferJob {
    private func sourceDescription(_ path: String) -> String {
        if case .download(let server) = kind { return "\(server.username)@\(server.host):\(path)" }
        return path
    }

    private func record(source: String, relativePath: String, size: UInt64, sha256: String?, verification: String,
                        failed: String? = nil) {
        TransferLog.append(TransferRecord(time: Date(), source: sourceDescription(source),
                                          destination: destination.appendingPathComponent(relativePath).path,
                                          size: size, sha256: sha256, verification: verification,
                                          result: failed == nil ? "ok" : "failed", detail: failed))
    }

    func handle(_ event: TransferEvent) {
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
            case .skipped: (nil, "none")
            case .alreadyPresent: (nil, "already-present")
            }
            record(source: f.path.description, relativePath: f.relativePath, size: f.size, sha256: hash, verification: method)
        } else if case .fileFailed(let f, let reason) = event {
            record(source: f.path.description, relativePath: f.relativePath, size: f.size, sha256: nil, verification: "none", failed: reason)
        }
        switch event {
        case .fileResumed(let f, let bytes):
            // Bytes from an earlier attempt of this job are already in the counter.
            if attempt == 0 { resumedBytes += Int64(bytes) }
            note("RESUME \(f.relativePath.uppercased()) · \(Self.bytes(Int64(bytes))) ON DISK")
        case .fileStarted(let f): note("GET \(f.relativePath.uppercased())")
        case .fileDownloaded(let f):
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
            case .sizeOnly(let why): note("✓ SIZE ONLY · \(f.relativePath.uppercased()) · \(why.uppercased())")
            case .skipped: note("✓ \(f.relativePath.uppercased()) · NOT VERIFIED")
            case .alreadyPresent:
                filesAlreadyPresent += 1
                presentBytes += Int64(f.size)
                note("= ALREADY PRESENT · \(f.relativePath.uppercased())")
            }
        case .fileFailed(let f, let reason):
            verifying[f.relativePath] = nil
            hashed[f.relativePath] = nil
            hashSizes[f.relativePath] = nil
            failures.append("\(f.relativePath): \(reason)")
            note("✕ \(f.relativePath.uppercased()) · \(reason.uppercased())", failure: true)
        }
    }

    func handle(_ event: CopyEvent) {
        if case .fileFinished(let f, _) = event, completedPaths.contains(f.relativePath) { return }
        if case .fileFinished(let f, let v) = event {
            let (hash, method): (String?, String) = switch v {
            case .nas(let h): (h, "nas-sha256")
            case .readBack(let h, _): (h, "read-back")
            case .cloned: (nil, "cloned")
            case .skipped: (nil, "none")
            case .alreadyPresent: (nil, "already-present")
            }
            record(source: f.path, relativePath: f.relativePath, size: f.size, sha256: hash, verification: method)
        } else if case .fileFailed(let f, let reason) = event {
            record(source: f.path, relativePath: f.relativePath, size: f.size, sha256: nil, verification: "none", failed: reason)
        }
        switch event {
        case .fileStarted(let f): note("COPY \(f.relativePath.uppercased())")
        case .fileCopied(let f):
            verifying[f.relativePath] = Date()
            note("COPIED \(f.relativePath.uppercased()) · VERIFYING")
        case .fileFinished(let f, let v):
            verifying[f.relativePath] = nil
            guard completedPaths.insert(f.relativePath).inserted else { return }
            filesFinished += 1
            switch v {
            case .nas(let hash):
                filesVerified += 1
                note("✓ SHA256 \(hash.prefix(8).uppercased())… VERIFIED ON NAS · \(f.relativePath.uppercased())")
            case .readBack(let hash, _):
                filesVerified += 1
                note("✓ SHA256 \(hash.prefix(8).uppercased())… READ-BACK · \(f.relativePath.uppercased())")
            case .cloned: note("✓ CLONED · \(f.relativePath.uppercased())")
            case .skipped: note("✓ \(f.relativePath.uppercased()) · NOT VERIFIED")
            case .alreadyPresent:
                filesAlreadyPresent += 1
                presentBytes += Int64(f.size)
                note("= ALREADY PRESENT · \(f.relativePath.uppercased())")
            }
        case .fileFailed(let f, let reason):
            verifying[f.relativePath] = nil
            failures.append("\(f.relativePath): \(reason)")
            note("✕ \(f.relativePath.uppercased()) · \(reason.uppercased())", failure: true)
        }
    }

    static func bytes(_ n: Int64) -> String {
        n == 0 ? "0 B" : n.formatted(.byteCount(style: .file)).uppercased()
    }
}
