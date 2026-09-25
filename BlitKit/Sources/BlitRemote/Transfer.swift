// Parallel, verified downloads (PRD R3.2, R3.3, R3.5, R4.1).
//
// Every file becomes one or more byte ranges on a shared queue; each connection
// pulls the next range when it's free, so faster connections do more work.
// When a file's last range lands, it's handed to a separate verifier so the
// connections keep downloading.

import BlitSFTP
import Foundation
import NIOCore
import Synchronization

// MARK: - Planning (pure)

public enum TransferPlan {
    /// Files at least this big are split across connections.
    public static let splitThreshold: UInt64 = 64 << 20

    /// Byte ranges for one file. Small files are one range. Large files get
    /// about four chunks per connection (32 MB–1 GB each), so a connection
    /// that finishes early can take more.
    public static func ranges(size: UInt64, connections: Int) -> [Range<UInt64>] {
        guard size >= splitThreshold, connections > 1 else { return [0..<size] }
        let mb: UInt64 = 1 << 20
        let target = size / UInt64(connections * 4)
        var chunk = min(max(target, 32 * mb), 1024 * mb)
        chunk = (chunk + mb - 1) / mb * mb
        return stride(from: UInt64(0), to: size, by: Int(chunk)).map { $0..<min($0 + chunk, size) }
    }

    /// A local path component for a remote name (PRD R3.10). Valid UTF-8 is
    /// kept; otherwise non-printable-ASCII bytes are percent-escaped.
    public static func localName(_ name: RemotePath) -> String {
        if let s = name.string, !s.contains("\0") { return s }
        return name.bytes.map { b in
            (0x20...0x7E).contains(b) && b != UInt8(ascii: "%") ? String(UnicodeScalar(b)) : String(format: "%%%02X", b)
        }.joined()
    }
}

extension RemotePath {
    /// The last path component.
    public var lastComponent: RemotePath {
        var bytes = self.bytes
        while bytes.count > 1, bytes.last == UInt8(ascii: "/") { bytes.removeLast() }
        if let slash = bytes.lastIndex(of: UInt8(ascii: "/")) { return RemotePath(bytes: Array(bytes[(slash + 1)...])) }
        return RemotePath(bytes: bytes)
    }
}

// MARK: - Model

public struct RemoteFile: Sendable, Equatable {
    public var path: RemotePath
    /// Destination path relative to the download folder.
    public var relativePath: String
    public var size: UInt64
    public var modificationTime: UInt32?
}

public enum TransferEvent: Sendable {
    case fileStarted(RemoteFile)
    /// Every byte has arrived; verification comes next.
    case fileDownloaded(RemoteFile)
    case fileFinished(RemoteFile, verification: Verification)
    case fileFailed(RemoteFile, String)
}

public enum Verification: Sendable, Equatable {
    case sha256(String)
    /// Checksums unavailable (e.g. no shell access); sizes matched (PRD R4.1 fallback).
    case sizeOnly(reason: String)
    case skipped
}

public struct TransferOptions: Sendable {
    public var verify = true
    public var overwrite = false
    public var concurrentVerifications = 2
    public init() {}
}

public final class ByteCounter: Sendable {
    private let value = Atomic<Int>(0)
    public init() {}
    public func add(_ n: Int) { value.add(n, ordering: .relaxed) }
    public var total: Int { value.load(ordering: .relaxed) }
}

public struct TransferSummary: Sendable {
    public var finished: [RemoteFile] = []
    public var verified = 0
    public var failed: [(file: RemoteFile, reason: String)] = []
}

// MARK: - Remote listing and hashing

/// Files under `root` (or `root` itself), with destination paths that start
/// with the root's own name, like `cp -r`.
public func remoteFiles(at root: RemotePath, using client: SFTPClient) async throws -> [RemoteFile] {
    let attributes = try await client.stat(root)
    let rootName = TransferPlan.localName(root.lastComponent)
    if !attributes.isDirectory {
        return [RemoteFile(path: root, relativePath: rootName, size: attributes.size ?? 0,
                           modificationTime: attributes.modificationTime)]
    }
    var files: [RemoteFile] = []
    var folders: [(RemotePath, String)] = [(root, rootName)]
    while let (folder, local) = folders.popLast() {
        for entry in try await client.list(folder) {
            let path = folder.appending(entry.filename)
            let name = local + "/" + TransferPlan.localName(entry.filename)
            if entry.attributes.isDirectory {
                folders.append((path, name))
            } else if entry.attributes.isRegularFile {
                files.append(RemoteFile(path: path, relativePath: name, size: entry.attributes.size ?? 0,
                                        modificationTime: entry.attributes.modificationTime))
            }
            // Symlinks and special files are skipped for now.
        }
    }
    return files.sorted { $0.relativePath < $1.relativePath }
}

/// `sha256sum` on the server over an exec channel. The path goes over stdin,
/// NUL-terminated, so it never touches a shell command line (PRD R4.1).
public struct RemoteHasher: Sendable {
    public let connection: SSHConnection
    /// Maps an SFTP path to the shell's view of it (they can differ, e.g. SFTPGo's virtual root).
    public let mapPath: @Sendable (RemotePath) -> RemotePath

    public init(connection: SSHConnection, mapPath: @escaping @Sendable (RemotePath) -> RemotePath = { $0 }) {
        self.connection = connection
        self.mapPath = mapPath
    }

    public func sha256(_ path: RemotePath) async throws -> String {
        let result = try await connection.run("xargs -0 sha256sum --", stdin: mapPath(path).bytes + [0])
        var line = String(decoding: result.stdout, as: UTF8.self)
        if line.hasPrefix("\\") { line.removeFirst() }   // sha256sum escapes odd filenames this way
        let hash = String(line.prefix(64))
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else {
            let err = String(decoding: result.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw SFTPError.unexpected("sha256sum failed: \(err.isEmpty ? line : err)")
        }
        return hash
    }
}

// MARK: - Download

actor FileJob {
    let file: RemoteFile
    let finalPath: String
    private var remaining: Int
    private var part: PartFile?
    private(set) var failure: String?

    init(file: RemoteFile, finalPath: String, ranges: Int) {
        self.file = file
        self.finalPath = finalPath
        self.remaining = ranges
    }

    var partPath: String { finalPath + ".blitpart" }

    /// Opens the part file on first use; returns whether this is the first range.
    func begin() throws -> (PartFile, first: Bool) {
        if let part { return (part, false) }
        let p = try PartFile.create(at: partPath, size: file.size)
        part = p
        return (p, true)
    }

    /// Call once per range, however it ended. Returns the part file when the
    /// last range is done and nothing failed. The file is only closed once no
    /// range can still be writing to it (a reused descriptor could otherwise
    /// receive another connection's late writes).
    func rangeEnded() -> PartFile? {
        remaining -= 1
        guard remaining == 0 else { return nil }
        if failure != nil {
            part?.close()
            part = nil
            return nil
        }
        return part
    }

    /// Records the first failure; returns true if this call recorded it.
    func fail(_ reason: String) -> Bool {
        guard failure == nil else { return false }
        failure = reason
        return true
    }
}

actor WorkQueue {
    private var items: [(job: FileJob, range: Range<UInt64>)]
    private var index = 0

    init(_ items: [(FileJob, Range<UInt64>)]) { self.items = items }

    func next() -> (job: FileJob, range: Range<UInt64>)? {
        guard index < items.count else { return nil }
        defer { index += 1 }
        return items[index]
    }
}

public func download(
    _ files: [RemoteFile],
    into directory: String,
    clients: [SFTPClient],
    hasher: RemoteHasher?,
    options: TransferOptions = TransferOptions(),
    counter: ByteCounter,
    events: @escaping @Sendable (TransferEvent) -> Void
) async -> TransferSummary {
    let summary = Mutex(TransferSummary())
    let fm = FileManager.default

    var work: [(FileJob, Range<UInt64>)] = []
    for file in files {
        let finalPath = directory + "/" + file.relativePath
        if fm.fileExists(atPath: finalPath), !options.overwrite {
            events(.fileFailed(file, "already exists (use --overwrite)"))
            summary.withLock { $0.failed.append((file, "already exists")) }
            continue
        }
        do {
            try fm.createDirectory(atPath: (finalPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        } catch {
            events(.fileFailed(file, "\(error)"))
            summary.withLock { $0.failed.append((file, "\(error)")) }
            continue
        }
        let ranges = TransferPlan.ranges(size: file.size, connections: clients.count)
        let job = FileJob(file: file, finalPath: finalPath, ranges: ranges.count)
        work += ranges.map { (job, $0) }
    }
    let queue = WorkQueue(work)
    let (finished, finishedSink) = AsyncStream.makeStream(of: (FileJob, PartFile).self)

    let record: @Sendable (FileJob, String) async -> Void = { job, reason in
        if await job.fail(reason) {
            events(.fileFailed(job.file, reason))
            summary.withLock { $0.failed.append((job.file, reason)) }
        }
    }

    await withTaskGroup(of: Void.self) { group in
        // One worker per connection, all pulling from the same queue.
        group.addTask {
            await withTaskGroup(of: Void.self) { workers in
                for client in clients {
                    workers.addTask {
                        while let (job, range) = await queue.next() {
                            if await job.failure == nil {
                                do {
                                    let (part, first) = try await job.begin()
                                    if first { events(.fileStarted(job.file)) }
                                    let stats = try await client.download(job.file.path, range: range, into: part,
                                                                          progress: counter.add)
                                    if stats.endedEarly {
                                        throw SFTPError.unexpected("file is shorter than listed (changed on the server?)")
                                    }
                                } catch {
                                    await record(job, "\(error)")
                                }
                            }
                            if let complete = await job.rangeEnded() {
                                events(.fileDownloaded(job.file))
                                finishedSink.yield((job, complete))
                            }
                        }
                    }
                }
            }
            finishedSink.finish()
        }

        // Verifiers: sync, checksum, set the modification time, rename.
        group.addTask {
            await withTaskGroup(of: Void.self) { verifiers in
                var running = 0
                for await (job, part) in finished {
                    if running >= options.concurrentVerifications {
                        await verifiers.next()
                        running -= 1
                    }
                    running += 1
                    verifiers.addTask {
                        do {
                            let verification = try await finalize(job: job, part: part, hasher: options.verify ? hasher : nil)
                            events(.fileFinished(job.file, verification: verification))
                            summary.withLock {
                                $0.finished.append(job.file)
                                if case .sha256 = verification { $0.verified += 1 }
                            }
                        } catch {
                            await record(job, "\(error)")
                        }
                    }
                }
            }
        }
    }
    return summary.withLock { $0 }
}

private func finalize(job: FileJob, part: PartFile, hasher: RemoteHasher?) async throws -> Verification {
    try part.sync()
    part.close()
    let file = job.file
    let partPath = await job.partPath
    let finalPath = job.finalPath

    var verification = Verification.skipped
    if let hasher {
        async let local = Task.detached { try localSHA256(path: partPath) }.value
        do {
            let remote = try await hasher.sha256(file.path)
            let mine = try await local
            guard mine == remote else {
                throw SFTPError.unexpected("SHA-256 mismatch: local \(mine), server \(remote); kept \(partPath)")
            }
            verification = .sha256(mine)
        } catch let error as SSHError {
            // No shell access: fall back to a size check (PRD R4.1).
            _ = try? await local
            verification = .sizeOnly(reason: error.description)
        }
    }
    if case .sha256 = verification {} else {
        let size = (try FileManager.default.attributesOfItem(atPath: partPath)[.size] as? NSNumber)?.uint64Value
        guard size == file.size else {
            throw SFTPError.unexpected("size mismatch: local \(size ?? 0), server \(file.size); kept \(partPath)")
        }
    }
    if let mtime = file.modificationTime {
        try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: TimeInterval(mtime))],
                                               ofItemAtPath: partPath)
    }
    guard rename(partPath, finalPath) == 0 else { throw POSIXFailure("rename to \(finalPath)") }
    return verification
}
