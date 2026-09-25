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

    var transferred: Int64 { Int64(counter.total) + resumedBytes }
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

    init(servers: ServerStore, verifier: BlitHostKeyVerifier) {
        self.servers = servers
        self.verifier = verifier
    }

    /// The job the strip shows: the running one, else the most recent.
    var featured: TransferJob? { jobs.first(where: \.isActive) ?? jobs.last(where: { $0.status != .queued }) ?? jobs.first }
    var queuedCount: Int { jobs.filter { $0.status == .queued }.count }

    func dismissFinished() {
        jobs.removeAll { !$0.isActive && $0.status != .queued }
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
        runNext()
        return nil
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
            onFinished?(job.destination)
            runNext()
        }
    }

    private func run(_ job: TransferJob) async {
        job.status = .preparing
        job.startedAt = Date()
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
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            let now = Date()
            let bytes = job.counter.total
            let rate = Double(bytes - last.bytes) / max(now.timeIntervalSince(last.time), 0.001) / 1e6
            last = (now, bytes)
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
        defer { for c in clients { Task { await c.connection.close() } } }
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
        let summary = await BlitRemote.download(files, into: job.destination.path, clients: clients, hasher: hasher,
                                                counter: job.counter) { event in
            Task { @MainActor in job.handle(event) }
        }
        job.filesFinished = summary.finished.count
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
                nas = NASVerifier(connection: connection, mountPoint: mount.mountPoint, nasRoot: root)
                job.nasVerified = true
                job.note("NAS \(login.host.uppercased()) · VERIFYING ON \(root.uppercased())")
            } catch {
                job.note("✕ NAS LOGIN FAILED · FALLING BACK TO READ-BACK · \(error)".uppercased(), failure: true)
            }
        }
        defer { if let nasConnection { Task { await nasConnection.close() } } }

        job.status = .running
        let summary = try await BlitLocal.copy(files, into: job.destination.path, nas: nas, counter: job.counter) { event in
            Task { @MainActor in job.handle(event) }
        }
        job.filesFinished = summary.finished.count
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
            }
        case .fileFailed(let f, let reason):
            verifying[f.relativePath] = nil
            failures.append("\(f.relativePath): \(reason)")
            note("✕ \(f.relativePath.uppercased()) · \(reason.uppercased())", failure: true)
        }
    }

    static func bytes(_ n: Int64) -> String {
        n.formatted(.byteCount(style: .file)).uppercased()
    }
}
