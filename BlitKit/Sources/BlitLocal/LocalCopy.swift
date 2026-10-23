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
    try localTree(at: root).files
}

/// Everything under a local root: files, folders (empty ones included) and
/// symlinks (not followed), so a copy keeps the whole structure (PRD R3.1).
public struct LocalTree: Sendable {
    public var files: [LocalFile] = []
    /// Folders, relative (root name first).
    public var directories: [String] = []
    public struct Symlink: Sendable { public let relativePath: String; public let source: String; public let target: String }
    public var symlinks: [Symlink] = []
    /// Items a copy can't carry (sockets, pipes, unreadable links), so the job
    /// can report them per item instead of dropping them silently (PRD R3.1).
    public var skipped: [(relativePath: String, reason: String)] = []
    /// Absolute paths of the folders at the source (for cleaning up after a move).
    public var sourceDirectories: [String] = []
}

public func localTree(at root: String) throws -> LocalTree {
    let fm = FileManager.default
    let rootURL = URL(fileURLWithPath: root).standardizedFileURL
    let name = rootURL.lastPathComponent
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
        throw POSIXFailure("\(root): not found")
    }
    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
    var tree = LocalTree()
    func add(_ url: URL, _ relative: String) throws {
        let v = try url.resourceValues(forKeys: Set(keys))
        if v.isSymbolicLink == true {
            if let target = try? fm.destinationOfSymbolicLink(atPath: url.path) {
                tree.symlinks.append(.init(relativePath: relative, source: url.path, target: target))
            } else {
                tree.skipped.append((relative, "couldn't read the symlink"))
            }
        } else if v.isRegularFile == true {
            tree.files.append(LocalFile(path: url.path, relativePath: relative, size: UInt64(v.fileSize ?? 0),
                                        modificationTime: v.contentModificationDate))
        } else if v.isDirectory == true {
            tree.directories.append(relative)
            tree.sourceDirectories.append(url.path)
        } else {
            tree.skipped.append((relative, "not a file, folder or symlink; skipped"))
        }
    }
    if !isDirectory.boolValue {
        try add(rootURL, name)
        return tree
    }
    tree.directories.append(name)
    tree.sourceDirectories.append(rootURL.path)
    // Relative paths straight from the walker: re-deriving them from each URL
    // breaks for a symlink whose target doesn't exist (its URL standardizes
    // differently from the root's).
    guard let walker = fm.enumerator(atPath: rootURL.path) else { return tree }
    while let relativePath = walker.nextObject() as? String {
        let last = (relativePath as NSString).lastPathComponent
        if last == ".DS_Store" || last.hasSuffix(".blitpart") { continue }
        try add(rootURL.appendingPathComponent(relativePath), name + "/" + relativePath)
    }
    tree.files.sort { $0.relativePath < $1.relativePath }
    return tree
}

/// Creates a tree's folders and symlinks under `directory` (its files are
/// copied by `copy`). Returns problems, one line each. Links are recreated as
/// they are at the source (like `cp -R`); nothing Blit writes later follows
/// them (SafePath), so a link pointing out of the folder stays only a link.
public func recreateStructure(directories: [String], symlinks: [LocalTree.Symlink], into directory: String) -> [String] {
    let fm = FileManager.default
    var problems: [String] = []
    for relative in directories {
        do {
            try SafePath.createDirectory(directory + "/" + relative, under: directory)
        } catch {
            problems.append("\(relative): \(error)")
        }
    }
    for link in symlinks {
        let path = directory + "/" + link.relativePath
        if let existing = try? fm.destinationOfSymbolicLink(atPath: path) {
            if existing != link.target { problems.append("\(link.relativePath): a different link already exists") }
            continue
        }
        if fm.fileExists(atPath: path) {
            problems.append("\(link.relativePath): something else already exists there")
            continue
        }
        do {
            try SafePath.createParents(of: path, under: directory)
            try fm.createSymbolicLink(atPath: path, withDestinationPath: link.target)
        } catch {
            problems.append("\(link.relativePath): \(error.localizedDescription)")
        }
    }
    return problems
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

    /// Every mounted volume, from the system's mount table without waiting on
    /// any of them. Unlike `of(_:)` (statfs), this never blocks on a hung SMB
    /// share, so it's safe on the main thread.
    public static func all() -> [MountInfo] {
        var list: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&list, MNT_NOWAIT)
        guard count > 0, let list else { return [] }
        func string<T>(_ tuple: T) -> String {
            withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        return (0..<Int(count)).map { i in
            MountInfo(mountPoint: string(list[i].f_mntonname), source: string(list[i].f_mntfromname),
                      fileSystem: string(list[i].f_fstypename))
        }
    }

    /// The volume mounted exactly at `mountPoint`, from the mount table (no waiting).
    public static func mounted(at mountPoint: String) -> MountInfo? {
        all().first { $0.mountPoint == mountPoint }
    }

    /// The volume a path is on (the longest mount point containing it), from
    /// the mount table and the path's text (no waiting). Like `of(_:)`, but
    /// safe on the main thread. Paths on the startup disk's firmlinked Data
    /// volume (/Users, /private…) report "/" rather than /System/Volumes/Data:
    /// same file system, and never SMB, which is what callers ask.
    public static func containing(_ path: String) -> MountInfo? {
        let path = LexicalPath.normalize(path)
        return all().filter { m in
            m.mountPoint == "/" || path == m.mountPoint || path.hasPrefix(m.mountPoint + "/")
        }.max { $0.mountPoint.count < $1.mountPoint.count }
    }
}

// MARK: - Copy session

public enum CopyEvent: Sendable {
    case fileStarted(LocalFile)
    case fileCopied(LocalFile)
    /// Bytes of the copy hashed so far (on the NAS, or read back here).
    case fileHashProgress(LocalFile, UInt64)
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
    /// The file at the destination has the same SHA-256 as the source
    /// (ExistsRule.replaceIfDifferent); left as is, and verified.
    case alreadyPresentVerified(String)
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
    /// When set, replaces `skipExistingSameSize` with the chosen rule (PRD R5.3).
    public var existsRule: ExistsRule?
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

    struct Item: Sendable { let file: LocalFile; let final: String; let replace: Bool }
    var work: [Item] = []
    var toCompare: [(LocalFile, String)] = []
    for (i, file) in files.enumerated() {
        var final = directory + "/" + file.relativePath
        var replace = options.overwrite
        let reason: String?
        if let other = collisions[i] {
            reason = "same local name as \(other) on this volume; skipped"
        } else if fm.fileExists(atPath: final), !options.overwrite {
            let size = (try? fm.attributesOfItem(atPath: final)[.size] as? NSNumber)?.uint64Value
            switch options.existsRule {
            case .replace?:
                replace = true
                reason = nil
            case .keepBoth?:
                final = ExistsRule.keepBothPath(final) { fm.fileExists(atPath: $0) }
                reason = nil
            case .replaceIfDifferent? where size != file.size:
                replace = true
                reason = nil
            case .replaceIfDifferent? where options.verify:
                toCompare.append((file, final))
                continue
            default:
                let skipSameSize = options.skipExistingSameSize || options.existsRule != nil
                if skipSameSize, size == file.size {
                    events(.fileFinished(file, verification: .alreadyPresent))
                    summary.withLock { $0.finished.append(file) }
                    continue
                }
                reason = skipSameSize ? "already exists with a different size" : "already exists (use --overwrite)"
            }
        } else {
            reason = nil
        }
        if let reason {
            events(.fileFailed(file, reason))
            summary.withLock { $0.failed.append((file, reason)) }
        } else {
            work.append(Item(file: file, final: final, replace: replace))
        }
    }

    // Same-size files under replaceIfDifferent: hash both copies (on the NAS
    // where it can, else by reading the existing copy). Identical is left as is
    // (verified); different is copied again and replaced.
    for (file, final) in toCompare {
        do {
            let source = try await Task.detached { try localSHA256(path: file.path) }.value
            let existing: String
            if let nas {
                existing = try await nas.hasher.sha256(RemotePath(final)).sha256   // mapped to the NAS path
            } else {
                existing = try await Task.detached { try readBackSHA256(path: final) }.value
            }
            if source == existing {
                events(.fileFinished(file, verification: .alreadyPresentVerified(source)))
                summary.withLock { $0.finished.append(file) }
            } else {
                work.append(Item(file: file, final: final, replace: true))
            }
        } catch {
            events(.fileFailed(file, "couldn't compare with the existing copy: \(error)"))
            summary.withLock { $0.failed.append((file, "\(error)")) }
        }
    }

    // Queue-wide space check before anything is written (PRD R5.8). Files that
    // will be APFS clones (same volume) take no new space.
    let destinationDeviceForSpace = deviceID(directory)
    let needed = work.reduce(UInt64(0)) { total, item in
        let clones = options.allowClone && destinationDeviceForSpace != nil && deviceID(item.file.path) == destinationDeviceForSpace
        return clones ? total : total + item.file.size
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
                while options.shouldStop?() != true, let item = queue.withLock({ $0.popFirst() }) {
                    let file = item.file
                    let final = item.final
                    let part = final + ".blitpart"
                    do {
                        // Not through a symlink in the destination tree (one recreated
                        // from the source earlier, or planted by a shared volume).
                        try SafePath.createParents(of: final, under: directory)
                        events(.fileStarted(file))
                        var verification: CopyVerification?
                        // Not a file that's only in the cloud (iCloud Drive, Proton Drive…):
                        // a clone of its placeholder would copy no data. Reading it
                        // below downloads it.
                        if options.allowClone, destinationDevice != nil, deviceID(file.path) == destinationDevice,
                           !isDataless(file.path) {
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
                                                            limiter: hashLimiter, shouldStop: stop) { events(.fileHashProgress(file, $0)) }
                        }
                        guard let verification else { throw POSIXFailure("copy \(file.path)", code: EIO) }
                        if let mtime = file.modificationTime {
                            try? FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: part)
                        }
                        // The copy can take hours: check the folders again just before the rename.
                        try SafePath.check(part, under: directory)
                        try renameIntoPlace(part, final, overwrite: item.replace)
                        events(.fileFinished(file, verification: verification))
                        summary.withLock {
                            $0.finished.append(file)
                            if case .nas = verification { $0.verifiedOnNAS += 1 }
                        }
                    } catch {
                        // A copy never resumes (a retry copies from the start), so a
                        // failed or stopped part is only dead weight on the share.
                        unlink(part)
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
                    limiter: AsyncLimiter, shouldStop: (@Sendable () -> Bool)?,
                    progress: @escaping @Sendable (UInt64) -> Void) async throws -> CopyVerification {
    guard verify else { return .skipped }
    var fallbackReason: String?
    if let nas {
        do {
            let remote = try await limiter.run { try await nas.hasher.sha256(RemotePath(part), progress: progress) }
            if let remoteSize = remote.size, remoteSize != size {
                throw CopyMismatch(description: "size on the NAS is \(remoteSize), expected \(size)")
            }
            guard remote.sha256 == sourceHash else {
                throw CopyMismatch(description: "SHA-256 mismatch: source \(sourceHash), NAS \(remote.sha256)")
            }
            return .nas(sourceHash)
        } catch let unavailable as RemoteHasher.Unavailable {
            // The NAS can't hash at all: fall back to a read-back, labelled as weaker.
            fallbackReason = "NAS check unavailable: \(unavailable.reason)"
        } catch let mismatch as CopyMismatch {
            throw mismatch
        } catch {
            // Interrupted (connection lost, Blit quitting): never downgrade to a
            // read-back, which a move would then trust. Fail the file; a retry copies again.
            throw CopyMismatch(description: "NAS verification interrupted (\(error))")
        }
    }
    let readBack = try await Task.detached { try readBackSHA256(path: part, progress: progress, shouldStop: shouldStop) }.value
    guard readBack == sourceHash else {
        throw CopyMismatch(description: "SHA-256 mismatch on read-back: source \(sourceHash), copy \(readBack)")
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
        throw CopyMismatch(description: "changed while it was copied (still being written?)")
    }
    let copied = (try? fm.attributesOfItem(atPath: part)[.size] as? NSNumber)?.uint64Value
    guard copied == file.size else {
        throw CopyMismatch(description: "copy is \(copied ?? 0) bytes, expected \(file.size)")
    }
}

/// Whether the file at `path` is only in the cloud: a File Provider placeholder
/// (iCloud Drive, Proton Drive…) whose data hasn't been downloaded.
func isDataless(_ path: String) -> Bool {
    var info = stat()
    guard lstat(path, &info) == 0 else { return false }
    return info.st_flags & 0x4000_0000 != 0   // SF_DATALESS
}

private func deviceID(_ path: String) -> dev_t? {
    var info = Darwin.stat()
    return stat(path, &info) == 0 ? info.st_dev : nil
}
