// Verified copies between local volumes, including SMB-mounted NAS shares
// (PRD R3.1, R3.5, R3.7, R3.8, R4.2, R5.8).

import BlitRemote
import BlitSFTP
import Darwin
import Foundation
import Synchronization

// MARK: - Model

public struct LocalFile: Sendable, Equatable {
    public var path: String
    /// Destination path relative to the destination folder.
    public var relativePath: String
    public var size: UInt64
    public var modificationTime: Date?
}

/// Files under `root` (or `root` itself), with relative paths that start with
/// the root's own name, like `cp -r`. Hidden files and package internals are
/// included; `.blitpart` leftovers and `.DS_Store` are skipped.
public func localFiles(at root: String) throws -> [LocalFile] {
    let fm = FileManager.default
    let rootURL = URL(fileURLWithPath: root).standardizedFileURL
    let name = rootURL.lastPathComponent
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
        throw POSIXFailure("\(root): not found")
    }
    let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
    func file(_ url: URL, _ relative: String) throws -> LocalFile? {
        let v = try url.resourceValues(forKeys: Set(keys))
        guard v.isRegularFile == true else { return nil }
        return LocalFile(path: url.path, relativePath: relative, size: UInt64(v.fileSize ?? 0), modificationTime: v.contentModificationDate)
    }
    if !isDirectory.boolValue { return try file(rootURL, name).map { [$0] } ?? [] }

    var result: [LocalFile] = []
    guard let walker = fm.enumerator(at: rootURL, includingPropertiesForKeys: keys) else { return [] }
    let prefix = rootURL.path.count + 1
    for case let url as URL in walker {
        let last = url.lastPathComponent
        if last == ".DS_Store" || last.hasSuffix(".blitpart") { continue }
        let relative = name + "/" + String(url.standardizedFileURL.path.dropFirst(prefix))
        if let f = try file(url, relative) { result.append(f) }
    }
    return result.sorted { $0.relativePath < $1.relativePath }
}

// MARK: - NAS-side verification

/// Verifies copies on the NAS itself: `sha256sum` over SSH on the share's path
/// there (PRD R1.6, R4.2).
public struct NASVerifier: Sendable {
    public let hasher: RemoteHasher
    /// Mount point on this Mac, e.g. "/Volumes/Media".
    public let mountPoint: String
    /// The same share's path on the NAS, e.g. "/volume1/Media".
    public let nasRoot: String

    public init(connection: SSHConnection, mountPoint: String, nasRoot: String) {
        self.mountPoint = mountPoint
        self.nasRoot = nasRoot
        let mount = mountPoint, root = nasRoot
        self.hasher = RemoteHasher(connection: connection) { path in
            RemotePath(NASVerifier.map(path.description, mountPoint: mount, nasRoot: root) ?? path.description)
        }
    }

    /// Translates a path under `mountPoint` to the NAS's view; nil if it's not under it.
    public static func map(_ localPath: String, mountPoint: String, nasRoot: String) -> String? {
        let mount = mountPoint.hasSuffix("/") ? String(mountPoint.dropLast()) : mountPoint
        guard localPath == mount || localPath.hasPrefix(mount + "/") else { return nil }
        return nasRoot + localPath.dropFirst(mount.count)
    }

    /// Asks the NAS where a share lives (e.g. "Media" → "/volume1/Media").
    public static func findShareRoot(_ share: String, on connection: SSHConnection) async throws -> String? {
        let result = try await connection.run("xargs -0 sh -c 'ls -d /volume*/\"$1\" 2>/dev/null' blit", stdin: Array(share.utf8) + [0])
        let line = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").first.map(String.init)
        return line?.isEmpty == false ? line : nil
    }
}

/// The SMB share behind a local path: its mount point and share name.
public struct MountInfo: Sendable, Equatable {
    public var mountPoint: String
    /// e.g. "//user@d1ll1N9eR._smb._tcp.local/Media"
    public var source: String
    public var fileSystem: String
    public var shareName: String { source.split(separator: "/").last.map(String.init) ?? "" }
    public var isSMB: Bool { fileSystem == "smbfs" }

    public static func of(_ path: String) -> MountInfo? {
        var fs = statfs()
        guard statfs(path, &fs) == 0 else { return nil }
        func string<T>(_ tuple: T) -> String {
            withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        return MountInfo(mountPoint: string(fs.f_mntonname), source: string(fs.f_mntfromname), fileSystem: string(fs.f_fstypename))
    }
}

// MARK: - Copy session

public enum CopyEvent: Sendable {
    case fileStarted(LocalFile)
    case fileCopied(LocalFile)
    case fileFinished(LocalFile, verification: CopyVerification)
    case fileFailed(LocalFile, String)
}

public enum CopyVerification: Sendable, Equatable {
    /// SHA-256 of the source matched `sha256sum` run on the NAS.
    case nas(String)
    /// Matched a read-back through this Mac (weaker: SMB may answer from cache).
    case readBack(String, reason: String?)
    /// APFS clone within one volume; the data is shared, not copied.
    case cloned
    case skipped
    /// A file of the same size was already at the destination; left as is.
    case alreadyPresent
}

public struct CopyOptions: Sendable {
    public var verify = true
    public var overwrite = false
    /// Files copied at once. One stream fills 1 GbE; a second hides per-file overhead on small files.
    public var concurrentFiles = 2
    /// Clone instead of copying when source and destination share an APFS volume.
    public var allowClone = true
    /// Treat an existing destination file of the same size as done (PRD R5.3).
    public var skipExistingSameSize = false
    /// Checked between blocks and files: true stops the copy (pause/cancel, PRD R5.2).
    public var shouldStop: (@Sendable () -> Bool)? = nil
    public init() {}
}

public struct CopySummary: Sendable {
    public var finished: [LocalFile] = []
    public var verifiedOnNAS = 0
    public var failed: [(file: LocalFile, reason: String)] = []
}

/// The copy doesn't match the source. Always fails the file (never falls back).
public struct CopyMismatch: Error, CustomStringConvertible, Sendable {
    public let description: String
}

public enum CopyPreflightError: Error, CustomStringConvertible, Sendable {
    case notEnoughSpace(needed: UInt64, available: UInt64, volume: String)

    public var description: String {
        switch self {
        case .notEnoughSpace(let needed, let available, let volume):
            let gb = { (n: UInt64) in String(format: "%.2f GB", Double(n) / 1e9) }
            return "not enough space on \(volume): need \(gb(needed)), \(gb(available)) available"
        }
    }
}

/// Free space on the volume holding `path`, for writes.
public func availableBytes(at path: String) -> UInt64? {
    var fs = statfs()
    guard statfs(path, &fs) == 0 else { return nil }
    return UInt64(fs.f_bavail) * UInt64(fs.f_bsize)
}

public func copy(
    _ files: [LocalFile],
    into directory: String,
    nas: NASVerifier?,
    options: CopyOptions = CopyOptions(),
    counter: ByteCounter,
    streamCounters: [ByteCounter]? = nil,
    events: @escaping @Sendable (CopyEvent) -> Void
) async throws -> CopySummary {
    let fm = FileManager.default
    try fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let summary = Mutex(CopySummary())
    let caseSensitive = (try? URL(fileURLWithPath: directory).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
        .volumeSupportsCaseSensitiveNames ?? false
    let collisions = TransferPlan.collisions(files.map(\.relativePath), caseSensitive: caseSensitive)

    var work: [LocalFile] = []
    for (i, file) in files.enumerated() {
        let final = directory + "/" + file.relativePath
        let reason: String?
        if let other = collisions[i] {
            reason = "same local name as \(other) on this volume; skipped"
        } else if fm.fileExists(atPath: final), !options.overwrite {
            let size = (try? fm.attributesOfItem(atPath: final)[.size] as? NSNumber)?.uint64Value
            if options.skipExistingSameSize, size == file.size {
                events(.fileFinished(file, verification: .alreadyPresent))
                summary.withLock { $0.finished.append(file) }
                continue
            }
            reason = options.skipExistingSameSize ? "already exists with a different size" : "already exists (use --overwrite)"
        } else {
            reason = nil
        }
        if let reason {
            events(.fileFailed(file, reason))
            summary.withLock { $0.failed.append((file, reason)) }
        } else {
            work.append(file)
        }
    }

    // Queue-wide space check before anything is written (PRD R5.8). Files that
    // will be APFS clones (same volume) take no new space.
    let destinationDeviceForSpace = deviceID(directory)
    let needed = work.reduce(UInt64(0)) { total, file in
        let clones = options.allowClone && destinationDeviceForSpace != nil && deviceID(file.path) == destinationDeviceForSpace
        return clones ? total : total + file.size
    }
    if let available = availableBytes(at: directory), needed > available {
        throw CopyPreflightError.notEnoughSpace(needed: needed, available: available, volume: MountInfo.of(directory)?.mountPoint ?? directory)
    }

    let queue = Mutex(work[...])
    let hashLimiter = AsyncLimiter(2)
    let destinationDevice = deviceID(directory)

    await withTaskGroup(of: Void.self) { group in
        for stream in 0..<max(1, options.concurrentFiles) {
            let streamCounter = streamCounters.flatMap { stream < $0.count ? $0[stream] : nil }
            let progress: @Sendable (Int) -> Void = { n in
                counter.add(n)
                streamCounter?.add(n)
            }
            group.addTask {
                while options.shouldStop?() != true, let file = queue.withLock({ $0.popFirst() }) {
                    let final = directory + "/" + file.relativePath
                    let part = final + ".blitpart"
                    do {
                        try FileManager.default.createDirectory(atPath: (final as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                        events(.fileStarted(file))
                        var verification: CopyVerification?
                        if options.allowClone, destinationDevice != nil, deviceID(file.path) == destinationDevice {
                            // Same volume: APFS clone (PRD R3.8). Other file systems
                            // (SMB, HFS+, exFAT) can't clone; they fall through to a copy.
                            unlink(part)
                            if clonefile(file.path, part, 0) == 0 {
                                progress(Int(file.size))
                                events(.fileCopied(file))
                                verification = .cloned
                            }
                        }
                        if verification == nil {
                            let stop = options.shouldStop
                            let sourceHash = try await Task.detached {
                                try StreamCopy.copy(from: file.path, to: part, progress: progress, shouldStop: stop)
                            }.value
                            // Source stability (as R3.9 for downloads): a file still being
                            // written would copy torn yet match its own streamed hash.
                            try checkUnchanged(file, part: part)
                            events(.fileCopied(file))
                            verification = try await verify(part: part, sourceHash: sourceHash, size: file.size,
                                                            nas: options.verify ? nas : nil, verify: options.verify,
                                                            limiter: hashLimiter)
                        }
                        guard let verification else { throw POSIXFailure("copy \(file.path)", code: EIO) }
                        if let mtime = file.modificationTime {
                            try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: part)
                        }
                        try renameIntoPlace(part, final, overwrite: options.overwrite)
                        events(.fileFinished(file, verification: verification))
                        summary.withLock {
                            $0.finished.append(file)
                            if case .nas = verification { $0.verifiedOnNAS += 1 }
                        }
                    } catch {
                        events(.fileFailed(file, "\(error)"))
                        summary.withLock { $0.failed.append((file, "\(error)")) }
                    }
                }
            }
        }
    }
    return summary.withLock { $0 }
}

private func verify(part: String, sourceHash: String, size: UInt64, nas: NASVerifier?, verify: Bool,
                    limiter: AsyncLimiter) async throws -> CopyVerification {
    guard verify else { return .skipped }
    var fallbackReason: String?
    if let nas {
        do {
            let remote = try await limiter.run { try await nas.hasher.sha256(RemotePath(part)) }
            if let remoteSize = remote.size, remoteSize != size {
                throw CopyMismatch(description: "size on the NAS is \(remoteSize), expected \(size); kept \(part)")
            }
            guard remote.sha256 == sourceHash else {
                throw CopyMismatch(description: "SHA-256 mismatch: source \(sourceHash), NAS \(remote.sha256); kept \(part)")
            }
            return .nas(sourceHash)
        } catch let unavailable as RemoteHasher.Unavailable {
            // The NAS can't hash at all: fall back to a read-back, labelled as weaker.
            fallbackReason = "NAS check unavailable: \(unavailable.reason)"
        } catch let mismatch as CopyMismatch {
            throw mismatch
        } catch {
            // Interrupted (connection lost, Blit quitting): never downgrade to a
            // read-back, which a move would then trust. Keep the part; retry.
            throw CopyMismatch(description: "NAS verification interrupted (\(error)); kept \(part)")
        }
    }
    let readBack = try await Task.detached { try readBackSHA256(path: part) }.value
    guard readBack == sourceHash else {
        throw CopyMismatch(description: "SHA-256 mismatch on read-back: source \(sourceHash), copy \(readBack); kept \(part)")
    }
    return .readBack(readBack, reason: fallbackReason)
}

/// Fails the file if the source changed while it was copied, or the copy isn't
/// the listed size.
private func checkUnchanged(_ file: LocalFile, part: String) throws {
    let fm = FileManager.default
    let now = try? fm.attributesOfItem(atPath: file.path)
    let size = (now?[.size] as? NSNumber)?.uint64Value
    let mtime = now?[.modificationDate] as? Date
    if size != file.size || (file.modificationTime != nil && mtime != file.modificationTime) {
        throw CopyMismatch(description: "changed while it was copied (still being written?); kept \(part)")
    }
    let copied = (try? fm.attributesOfItem(atPath: part)[.size] as? NSNumber)?.uint64Value
    guard copied == file.size else {
        throw CopyMismatch(description: "copy is \(copied ?? 0) bytes, expected \(file.size); kept \(part)")
    }
}

private func deviceID(_ path: String) -> dev_t? {
    var info = Darwin.stat()
    return stat(path, &info) == 0 ? info.st_dev : nil
}
