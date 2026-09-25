// Transfers started by drag and drop (PRD R2.10): a queue run one job at a
// time, using BlitKit's parallel verified download (server → local) or
// verified copy (local → local, cloning within one APFS volume).

import BlitLocal
import BlitRemote
import BlitSFTP
import CoreTransferable
import Foundation
import Observation
import UniformTypeIdentifiers
import UserNotifications

extension UTType {
    /// Locations dragged within Blit (declared in Support/Info.plist).
    static let blitLocations = UTType(exportedAs: "com.banastas.blit.locations")
}

struct TransferPayload: Codable, Transferable {
    var locations: [BrowseLocation]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .blitLocations)
    }
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
    enum Kind { case download(ServerConfig), copy }
    enum Status: Equatable { case queued, preparing, running, finished, failed(String) }

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
    /// Every file was already there; nothing was transferred.
    var allAlreadyPresent: Bool { fileCount > 0 && filesAlreadyPresent == fileCount }
    var progress: Double { totalBytes > 0 ? min(1, Double(transferred) / Double(totalBytes)) : 0 }
    var isActive: Bool { status == .preparing || status == .running }
    /// How files are verified, for the HUD.
    var verificationMethod: String {
        if case .download = kind { return "SERVER SHA256" }
        return nasVerified ? "NAS SHA256" : "READ-BACK"
    }
    var nasVerified = false
    /// Include hidden files when walking folders (captured at drop time).
    var includeHidden = false

    func note(_ text: String, failure: Bool = false) {
        log.append(LogLine(text: text, isFailure: failure))
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }
}

@MainActor
@Observable
final class TransferManager {
    private(set) var jobs: [TransferJob] = []
    /// Called when a job finishes, with its destination (to refresh the browser).
    @ObservationIgnored var onFinished: ((URL) -> Void)?
    @ObservationIgnored private let servers: ServerStore
    @ObservationIgnored private let verifier: BlitHostKeyVerifier
    @ObservationIgnored private var running = false
    /// Connections held by the running job, closed if Blit quits mid-transfer.
    @ObservationIgnored private var liveConnections: [SSHConnection] = []
    @ObservationIgnored private var isQuitting = false
    @ObservationIgnored private var notificationProblemReported = false

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
    }

    /// The full HUD is open (click the count in the condensed strip).
    var isExpanded = false
    /// Files handed to Blit from Finder (Services › Send to Blit…), waiting
    /// for the user to pick a destination.
    var pendingExternalFiles: [URL] = []

    /// The job the strip shows: the running one, else the most recent.
    var featured: TransferJob? { jobs.first(where: \.isActive) ?? jobs.last(where: { $0.status != .queued }) ?? jobs.first }
    var queuedCount: Int { jobs.filter { $0.status == .queued }.count }

    func dismissFinished() {
        jobs.removeAll { !$0.isActive && $0.status != .queued }
        if jobs.isEmpty { isExpanded = false }
    }

    /// Queues a transfer of `sources` into `destination`. Returns a message
    /// if it can't be done.
    func enqueue(_ sources: [BrowseLocation], to destination: BrowseLocation, destinationName: String,
                 includeHidden: Bool = false) -> String? {
        guard let folder = destination.localURL else {
            return "Uploading to a server isn't supported yet. Drop onto a local folder, drive or NAS share."
        }
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
            jobs.append(job)
        }
        if !local.isEmpty {
            jobs.append(TransferJob(kind: .copy, sources: local.map { .local($0) }, destination: folder,
                                    title: Self.title(local.map(\.lastPathComponent)), destinationName: destinationName))
        }
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
    }

    private static var queueURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Blit/queue.json")
    }

    /// Saves unfinished jobs, so a quit or restart doesn't lose them.
    private func saveQueue() {
        // While quitting, the running job fails as its connections close; keep it saved.
        guard !isQuitting else { return }
        let pending = jobs.filter { $0.status == .queued || $0.isActive }.map { job -> SavedJob in
            var serverID: UUID?
            if case .download(let server) = job.kind { serverID = server.id }
            return SavedJob(serverID: serverID, sources: job.sources, destination: job.destination, title: job.title,
                            destinationName: job.destinationName, includeHidden: job.includeHidden)
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
            job.restored = true
            job.note("RESTORED FROM LAST SESSION · RESUMING")
            jobs.append(job)
        }
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
            onFinished?(job.destination)
            await notify(job)
            runNext()
        }
    }

    private func run(_ job: TransferJob) async {
        job.status = .preparing
        job.startedAt = Date()
        saveQueue()
        let sampler = Task { await sample(job) }
        defer { sampler.cancel() }
        do {
            switch job.kind {
            case .download(let server): try await download(job, from: server)
            case .copy: try await copy(job)
            }
            job.status = job.failures.isEmpty ? .finished : .failed("\(job.failures.count) failed")
        } catch {
            job.status = .failed("\(error)")
            job.note("✕ \(error)", failure: true)
        }
        job.finishedAt = Date()
        job.rate = 0
    }

    /// Samples throughput once a second for the rate and histogram.
    private func sample(_ job: TransferJob) async {
        var last = (time: Date(), bytes: 0)
        var lastPer: [Int] = []
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
            guard job.status == .running else { continue }
            job.rate = rate
            job.peakRate = max(job.peakRate, rate)
            job.history.append(rate)
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
        _ = await BlitRemote.download(files, into: job.destination.path, clients: clients, hasher: hasher,
                                      options: options, counter: job.counter,
                                      connectionCounters: job.connectionCounters) { event in
            Task { @MainActor in job.handle(event) }
        }
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
        _ = try await BlitLocal.copy(files, into: job.destination.path, nas: nas, options: options, counter: job.counter,
                                     streamCounters: job.connectionCounters) { event in
            Task { @MainActor in job.handle(event) }
        }
    }
}

extension TransferJob {
    func handle(_ event: TransferEvent) {
        switch event {
        case .fileResumed(let f, let bytes):
            resumedBytes += Int64(bytes)
            note("RESUME \(f.relativePath.uppercased()) · \(Self.bytes(Int64(bytes))) ON DISK")
        case .fileStarted(let f): note("GET \(f.relativePath.uppercased())")
        case .fileDownloaded(let f):
            verifying[f.relativePath] = Date()
            note("DOWNLOADED \(f.relativePath.uppercased()) · VERIFYING")
        case .fileFinished(let f, let v):
            verifying[f.relativePath] = nil
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
            failures.append("\(f.relativePath): \(reason)")
            note("✕ \(f.relativePath.uppercased()) · \(reason.uppercased())", failure: true)
        }
    }

    func handle(_ event: CopyEvent) {
        switch event {
        case .fileStarted(let f): note("COPY \(f.relativePath.uppercased())")
        case .fileCopied(let f):
            verifying[f.relativePath] = Date()
            note("COPIED \(f.relativePath.uppercased()) · VERIFYING")
        case .fileFinished(let f, let v):
            verifying[f.relativePath] = nil
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
