// Parallel, verified, resumable downloads (PRD R3.2, R3.3, R3.5, R3.6, R3.9, R4.1).
//
// Every file becomes one or more byte ranges on a shared queue; each connection
// pulls the next range when it's free, so faster connections do more work.
// When a file's first range is handed out, the server starts hashing it, so
// the hash reads the file alongside the download (while it's in the server's
// cache) instead of re-reading it cold afterwards; when its last range lands,
// a separate verifier finishes the file so connections keep downloading.

import BlitSFTP
import Foundation
import NIOCore
import Synchronization

// MARK: - Planning (pure)

public enum TransferPlan {
    /// Files at least this big are split across connections.
    public static let splitThreshold: UInt64 = 64 << 20
    static let mb: UInt64 = 1 << 20

    /// Chunk size for a file: about four chunks per connection, 32–256 MB, whole
    /// megabytes. The 256 MB cap bounds what an interruption can cost (PRD R3.6).
    public static func chunkSize(size: UInt64, connections: Int) -> UInt64 {
        guard size >= splitThreshold, connections > 1 else { return max(size, 1) }
        let target = size / UInt64(connections * 4)
        let chunk = min(max(target, 32 * mb), 256 * mb)
        return (chunk + mb - 1) / mb * mb
    }

    /// Byte ranges covering `gaps` (the parts still missing) in chunks.
    public static func ranges(size: UInt64, connections: Int, gaps: [Range<UInt64>]? = nil) -> [Range<UInt64>] {
        let chunk = chunkSize(size: size, connections: connections)
        let missing = gaps ?? [0..<size]
        if size == 0 { return [0..<0] }
        return missing.flatMap { gap in
            stride(from: gap.lowerBound, to: gap.upperBound, by: Int(chunk)).map { $0..<min($0 + chunk, gap.upperBound) }
        }
    }

    /// Indexes of paths that would land on the same local file as an earlier
    /// path in the list (PRD R3.10), mapped to the path they collide with.
    /// APFS treats Unicode normalization forms as the same name, and is
    /// case-insensitive unless formatted case-sensitive.
    public static func collisions(_ relativePaths: [String], caseSensitive: Bool) -> [Int: String] {
        var seen: [String: String] = [:]
        var result: [Int: String] = [:]
        for (i, path) in relativePaths.enumerated() {
            var key = path.precomposedStringWithCanonicalMapping
            if !caseSensitive { key = key.lowercased() }
            if let earlier = seen[key] { result[i] = earlier } else { seen[key] = path }
        }
        return result
    }

    /// A local path component for a remote name (PRD R3.10). Valid UTF-8 is
    /// kept; otherwise non-printable-ASCII bytes are percent-escaped. A name
    /// can never add path structure: "/" is escaped, and "." or ".." (which a
    /// hostile server could send) become "%2E"/"%2E%2E", so every component
    /// stays inside the download folder.
    public static func localName(_ name: RemotePath) -> String {
        let escaped: String
        if let s = name.string, !s.contains("\0") {
            escaped = s.replacingOccurrences(of: "/", with: "%2F")
        } else {
            escaped = name.bytes.map { b in
                (0x20...0x7E).contains(b) && b != UInt8(ascii: "%") && b != UInt8(ascii: "/")
                    ? String(UnicodeScalar(b)) : String(format: "%%%02X", b)
            }.joined()
        }
        switch escaped {
        case "": return "%00"
        case ".": return "%2E"
        case "..": return "%2E%2E"
        default: return escaped
        }
    }

    /// True if `relativePath` stays inside the folder it's joined to.
    public static func isContained(_ relativePath: String) -> Bool {
        !relativePath.hasPrefix("/") && !relativePath.split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0 == ".." || $0 == "." || $0.isEmpty }
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
    /// Resuming a partial download: `bytes` were already on disk.
    case fileResumed(RemoteFile, bytes: UInt64)
    case fileStarted(RemoteFile)
    /// Every byte has arrived; verification comes next.
    case fileDownloaded(RemoteFile)
    /// The server has hashed `bytes` of the file so far (where it can report it).
    case fileHashProgress(RemoteFile, bytes: UInt64)
    case fileFinished(RemoteFile, verification: Verification)
    case fileFailed(RemoteFile, String)
}

public enum Verification: Sendable, Equatable {
    /// `cached` means the server reused a hash it computed earlier for this exact file.
    case sha256(String, cached: Bool)
    /// Checksums unavailable (e.g. no shell access); sizes matched (PRD R4.1 fallback).
    case sizeOnly(reason: String)
    case skipped
    /// A file of the same size was already at the destination; left as is.
    case alreadyPresent
    /// The file already at the destination has the same SHA-256 as the source
    /// (ExistsRule.replaceIfDifferent); left as is, and verified.
    case alreadyPresentVerified(String)
}

/// What to do when a file already exists at the destination (PRD R5.3).
public enum ExistsRule: String, Codable, Sendable, CaseIterable {
    /// Same size: leave it (trusting the size). Different size: fail the file.
    case skipIfSameSize
    /// Compare SHA-256: identical is left (verified); different is replaced.
    case replaceIfDifferent
    /// Always transfer again and replace it.
    case replace
    /// Keep it and save the new file as "name 2.ext".
    case keepBoth

    /// "Movie 2.mkv", "Movie 3.mkv"…: the first name that doesn't exist yet.
    public static func keepBothPath(_ path: String, exists: (String) -> Bool) -> String {
        let url = URL(fileURLWithPath: path)
        let folder = url.deletingLastPathComponent()
        let ext = url.pathExtension.contains(" ") ? "" : url.pathExtension
        let base = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent("\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")).path
            if !exists(candidate) { return candidate }
            n += 1
        }
    }
}

public struct TransferOptions: Sendable {
    public var verify = true
    public var overwrite = false
    /// Treat an existing destination file of the same size as done (PRD R5.3),
    /// e.g. when a queue restored after relaunch runs again. A different size
    /// still fails unless `overwrite`.
    public var skipExistingSameSize = false
    /// When set, replaces `skipExistingSameSize` with the chosen rule.
    public var existsRule: ExistsRule?
    public var concurrentHashes = 3
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
    public var resumedBytes: UInt64 = 0
    public var failed: [(file: RemoteFile, reason: String)] = []
}

// MARK: - Remote listing

/// Files under `root` (or `root` itself), with destination paths that start
/// with the root's own name, like `cp -r`. Hidden entries (names starting
/// with ".", such as a torrent client's `.parts` files) are skipped unless
/// `includeHidden`.
public func remoteFiles(at root: RemotePath, using client: SFTPClient, includeHidden: Bool = false) async throws -> [RemoteFile] {
    try await remoteTree(at: root, using: client, includeHidden: includeHidden).files
}

/// Everything under a remote root: its files, its folders (so empty ones can
/// be recreated, PRD R3.1) and the symlinks that were skipped.
public struct RemoteTree: Sendable {
    public var files: [RemoteFile] = []
    /// Folders, relative to the download folder (root name first), empty ones included.
    public var directories: [String] = []
    /// The same folders on the server, for cleaning up after a move.
    public var sourceDirectories: [RemotePath] = []
    /// Relative paths of symlinks, which aren't followed or recreated from servers.
    public var skippedSymlinks: [String] = []
}

public func remoteTree(at root: RemotePath, using client: SFTPClient, includeHidden: Bool = false) async throws -> RemoteTree {
    let attributes = try await client.stat(root)
    let rootName = TransferPlan.localName(root.lastComponent)
    var tree = RemoteTree()
    if !attributes.isDirectory {
        tree.files = [RemoteFile(path: root, relativePath: rootName, size: attributes.size ?? 0,
                                 modificationTime: attributes.modificationTime)]
        return tree
    }
    var folders: [(RemotePath, String)] = [(root, rootName)]
    while let (folder, local) = folders.popLast() {
        tree.directories.append(local)
        tree.sourceDirectories.append(folder)
        for entry in try await client.list(folder) {
            if !includeHidden, entry.filename.bytes.first == UInt8(ascii: ".") { continue }
            let path = folder.appending(entry.filename)
            let name = local + "/" + TransferPlan.localName(entry.filename)
            if entry.attributes.isDirectory {
                folders.append((path, name))
            } else if entry.attributes.isRegularFile {
                tree.files.append(RemoteFile(path: path, relativePath: name, size: entry.attributes.size ?? 0,
                                             modificationTime: entry.attributes.modificationTime))
            } else if entry.attributes.isSymlink {
                tree.skippedSymlinks.append(name)
            }
        }
    }
    tree.files.sort { $0.relativePath < $1.relativePath }
    tree.directories.sort()
    return tree
}

// MARK: - Remote hashing

/// SHA-256 on the server over an exec channel (PRD R4.1). The path goes over
/// stdin NUL-terminated and reaches the script as "$1", so it never touches a
/// shell command line. Results are cached in ~/.cache/blit/sha256 on the
/// server, keyed by path, size and mtime, so no file is hashed twice.
public struct RemoteHasher: Sendable {
    public struct Result: Sendable, Equatable {
        public var sha256: String
        /// Size and mtime the server saw when hashing (nil from the plain fallback).
        public var size: UInt64?
        public var modificationTime: UInt32?
        public var cached: Bool
    }

    /// The server can't hash files at all (no shell access, no sha256sum), as
    /// opposed to a hash that was interrupted (connection lost). Only this
    /// allows falling back to a size check.
    public struct Unavailable: Error, CustomStringConvertible {
        public let reason: String
        public var description: String { reason }
    }

    public let connection: SSHConnection
    /// Maps an SFTP path to the shell's view of it (they can differ, e.g. SFTPGo's virtual root).
    public let mapPath: @Sendable (RemotePath) -> RemotePath

    public init(connection: SSHConnection, mapPath: @escaping @Sendable (RemotePath) -> RemotePath = { $0 }) {
        self.connection = connection
        self.mapPath = mapPath
    }

    /// POSIX sh; no single quotes, since it's passed inside '…'. Needs GNU or
    /// BusyBox `stat -c`. Prints "sha256 size mtime cached|computed". Where
    /// GNU dd has status=progress, the bytes hashed so far go to stderr about
    /// once a second.
    ///
    /// Only a complete, successful read is cached or reported: dd's exit
    /// status is checked (a failed read would otherwise hash a truncated
    /// stream), and the file must be unchanged afterwards. The cache key adds
    /// ctime and inode to size and mtime, so a same-size re-upload that
    /// preserves mtime isn't served a stale hash. BLIT_NOCACHE=1 recomputes.
    static let script = #"""
    p=$1
    set -- $(stat -L -c "%s %Y %Z %i" -- "$p" 2>/dev/null)
    [ $# -eq 4 ] || exit 3
    before="$1 $2 $3 $4"
    d="${XDG_CACHE_HOME:-$HOME/.cache}/blit/sha256"
    k=$(printf "%s|%s" "$p" "$before" | sha256sum | cut -c1-64)
    if [ -z "$BLIT_NOCACHE" ] && [ -s "$d/$k" ]; then
      h=$(cut -c1-64 "$d/$k"); c=cached
    else
      mkdir -p "$d" || exit 4
      t="$d/.status.$$"
      if dd if=/dev/null of=/dev/null status=progress 2>/dev/null; then
        h=$( { dd if="$p" bs=4M status=progress; echo $? > "$t"; } | sha256sum | cut -c1-64 )
      else
        h=$( { cat -- "$p"; echo $? > "$t"; } | sha256sum | cut -c1-64 )
      fi
      s=$(cat "$t" 2>/dev/null); rm -f "$t"
      [ "$s" = 0 ] || exit 5
      [ ${#h} -eq 64 ] || exit 4
      [ "$(stat -L -c "%s %Y %Z %i" -- "$p" 2>/dev/null)" = "$before" ] || exit 6
      printf "%s\n" "$h" > "$d/$k.$$" && mv -f "$d/$k.$$" "$d/$k"
      c=computed
    fi
    printf "%s %s %s %s\n" "$h" "$1" "$2" "$c"
    """#

    /// `progress` gets the bytes hashed so far, where the server can report them.
    /// `bypassCache` recomputes instead of trusting a cached hash.
    public func sha256(_ path: RemotePath, bypassCache: Bool = false,
                       progress: (@Sendable (UInt64) -> Void)? = nil) async throws -> Result {
        let stdin = mapPath(path).bytes + [0]
        var onStderr: (@Sendable ([UInt8]) -> Void)?
        if let progress {
            onStderr = { chunk in
                if let bytes = RemoteHasher.progressBytes(chunk) { progress(bytes) }
            }
        }
        let cachedRun: SSHConnection.CommandResult
        do {
            let prefix = bypassCache ? "env BLIT_NOCACHE=1 " : ""
            cachedRun = try await connection.run("\(prefix)xargs -0 sh -c '\(Self.script)' blit", stdin: stdin, onStderr: onStderr)
        } catch SSHError.channelRequestRefused(let what) {
            throw Unavailable(reason: "the server refused to run commands (\(what))")
        }
        if let result = Self.parse(scriptOutput: cachedRun.stdout) { return result }
        // An exec that ended without an exit status was cut off (connection
        // lost mid-hash), not a server that can't hash.
        guard cachedRun.exitStatus != nil else {
            throw SSHError.disconnected("the hash was interrupted")
        }

        // Fallback: plain sha256sum (no cache, no size/mtime).
        let plain = try await connection.run("xargs -0 sha256sum --", stdin: stdin)
        var line = String(decoding: plain.stdout, as: UTF8.self)
        if line.hasPrefix("\\") { line.removeFirst() }   // sha256sum escapes odd filenames this way
        let hash = String(line.prefix(64))
        guard Self.isHash(hash) else {
            guard let status = plain.exitStatus else { throw SSHError.disconnected("the hash was interrupted") }
            let err = String(decoding: plain.stderr, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            // Only "no such command" (126/127) means the server can't hash at all.
            // Anything else (unreadable file, a path the shell sees differently,
            // a noisy login script) is a per-file failure: kept and retried, never
            // accepted on size alone (PRD R4.1).
            if status == 126 || status == 127 {
                throw Unavailable(reason: "sha256sum isn't available on the server: \(err.isEmpty ? line : err)")
            }
            throw SFTPError.unexpected("the server couldn't hash the file (exit \(status)): \(err.isEmpty ? line : err)")
        }
        return Result(sha256: hash, size: nil, modificationTime: nil, cached: false)
    }

    static func parse(scriptOutput: [UInt8]) -> Result? {
        let fields = String(decoding: scriptOutput, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard fields.count == 4, isHash(String(fields[0])),
              let size = UInt64(fields[1]), let mtime = UInt32(fields[2]),
              fields[3] == "cached" || fields[3] == "computed" else { return nil }
        return Result(sha256: String(fields[0]), size: size, modificationTime: mtime, cached: fields[3] == "cached")
    }

    static func isHash(_ s: String) -> Bool { s.count == 64 && s.allSatisfy(\.isHexDigit) }

    /// The latest byte count in GNU dd progress output
    /// ("\r1073741824 bytes (1.1 GB, 1.0 GiB) copied, 4 s, 268 MB/s").
    static func progressBytes(_ chunk: [UInt8]) -> UInt64? {
        let text = String(decoding: chunk, as: UTF8.self)
        var latest: UInt64?
        for line in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
            let words = line.split(separator: " ")
            if words.count >= 2, words[1] == "bytes" || words[1] == "byte", let n = UInt64(words[0]) { latest = n }
        }
        return latest
    }
}

/// Limits how many operations run at once (e.g. server-side hashes sharing a disk).
public actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(_ limit: Int) { self.limit = max(1, limit) }

    public func run<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        if running >= limit { await withCheckedContinuation { waiters.append($0) } } else { running += 1 }
        defer {
            if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
        }
        // Cancelled while waiting (e.g. the file failed): don't start the work,
        // just pass the slot on.
        try Task.checkCancellation()
        return try await body()
    }
}

// MARK: - Resume state

/// Sidecar next to a `.blitpart`: which byte ranges are on disk, and for which
/// version of the remote file.
struct PartState: Codable, Equatable {
    var version = 1
    var remotePath: Data
    var size: UInt64
    var modificationTime: UInt32?
    var done: ByteRangeSet

    func matches(_ file: RemoteFile) -> Bool {
        version == 1 && remotePath == Data(file.path.bytes) && size == file.size && modificationTime == file.modificationTime
    }

    static func load(_ path: String) -> PartState? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? JSONDecoder().decode(PartState.self, from: data)
    }

    func save(_ path: String) throws {
        try JSONEncoder().encode(self).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

// MARK: - Download

actor FileJob {
    let file: RemoteFile
    let finalPath: String
    private var state: PartState
    private let resuming: Bool
    private let rangeCount: Int
    private var unassigned: Int
    private var remaining: Int
    private var part: PartFile?
    private(set) var failure: String?
    private(set) var remoteHash: Task<RemoteHasher.Result, Error>?

    /// Replace a file at the final path (ExistsRule.replace, or different content).
    let replace: Bool

    init(file: RemoteFile, finalPath: String, state: PartState, resuming: Bool, ranges: Int, replace: Bool = false) {
        self.file = file
        self.finalPath = finalPath
        self.replace = replace
        self.state = state
        self.resuming = resuming
        self.rangeCount = ranges
        self.unassigned = ranges
        self.remaining = ranges
    }

    var partPath: String { finalPath + ".blitpart" }
    var statePath: String { finalPath + ".blitpart.state" }

    var hasStarted: Bool { part != nil }

    /// Opens the part file on first use; returns whether this is the first range.
    func begin() throws -> (PartFile, first: Bool) {
        if let part { return (part, false) }
        let p = resuming ? try PartFile.reopen(at: partPath, size: file.size) : try PartFile.create(at: partPath, size: file.size)
        part = p
        if !resuming { try state.save(statePath) }
        return (p, true)
    }

    /// Call when a range is handed to a connection; true for the file's last one.
    /// Call as each range is handed out; true for the first one.
    func assigned() -> Bool {
        unassigned -= 1
        return unassigned == rangeCount - 1
    }

    func startRemoteHash(_ start: @escaping @Sendable () async throws -> RemoteHasher.Result) {
        if remoteHash == nil { remoteHash = Task { try await start() } }
    }

    /// Call once per range, however it ended. Records completed ranges for
    /// resume, and returns the part file when the last range is done and
    /// nothing failed. The file is only closed once no range can still be
    /// writing to it (a reused descriptor could otherwise receive late writes).
    func rangeEnded(_ range: Range<UInt64>, succeeded: Bool) -> PartFile? {
        if succeeded, failure == nil {
            // Bytes must be on disk before the state says they are: after a power
            // loss, resume trusts `done` (PRD R3.6).
            if (try? part?.sync()) != nil {
                state.done.insert(range)
                try? state.save(statePath)
            }
        }
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
        remoteHash?.cancel()
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
    connectionCounters: [ByteCounter]? = nil,
    events: @escaping @Sendable (TransferEvent) -> Void
) async -> TransferSummary {
    let summary = Mutex(TransferSummary())
    let fm = FileManager.default
    let hashLimiter = AsyncLimiter(options.concurrentHashes)
    let effectiveHasher = options.verify ? hasher : nil

    let (finished, finishedSink) = AsyncStream.makeStream(of: (FileJob, PartFile).self)
    var work: [(FileJob, Range<UInt64>)] = []
    var alreadyComplete: [FileJob] = []

    try? fm.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let caseSensitive = (try? URL(fileURLWithPath: directory).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
        .volumeSupportsCaseSensitiveNames ?? false
    let collisions = TransferPlan.collisions(files.map(\.relativePath), caseSensitive: caseSensitive)

    var toCompare: [(RemoteFile, String)] = []
    for (index, file) in files.enumerated() {
        guard TransferPlan.isContained(file.relativePath) else {
            let reason = "unsafe name from the server (would leave the download folder); skipped"
            events(.fileFailed(file, reason))
            summary.withLock { $0.failed.append((file, reason)) }
            continue
        }
        if let other = collisions[index] {
            let reason = "same local name as \(other) on this volume; skipped"
            events(.fileFailed(file, reason))
            summary.withLock { $0.failed.append((file, reason)) }
            continue
        }
        var finalPath = directory + "/" + file.relativePath
        var replace = false
        if fm.fileExists(atPath: finalPath), !options.overwrite {
            let size = (try? fm.attributesOfItem(atPath: finalPath)[.size] as? NSNumber)?.uint64Value
            switch options.existsRule {
            case .replace?:
                replace = true
            case .keepBoth?:
                finalPath = ExistsRule.keepBothPath(finalPath) { fm.fileExists(atPath: $0) }
            case .replaceIfDifferent? where size != file.size:
                replace = true
            case .replaceIfDifferent? where effectiveHasher != nil:
                // Same size: compare hashes before deciding (below).
                toCompare.append((file, finalPath))
                continue
            default:
                let skipSameSize = options.skipExistingSameSize || options.existsRule != nil
                if skipSameSize, size == file.size {
                    events(.fileFinished(file, verification: .alreadyPresent))
                    summary.withLock { $0.finished.append(file) }
                } else {
                    let reason = skipSameSize ? "already exists with a different size" : "already exists (use --overwrite)"
                    events(.fileFailed(file, reason))
                    summary.withLock { $0.failed.append((file, reason)) }
                }
                continue
            }
        }
        do {
            try fm.createDirectory(atPath: (finalPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        } catch {
            events(.fileFailed(file, "\(error)"))
            summary.withLock { $0.failed.append((file, "\(error)")) }
            continue
        }

        // Resume if a matching part file and state exist (PRD R3.6).
        let partPath = finalPath + ".blitpart"
        let statePath = partPath + ".state"
        var state = PartState(remotePath: Data(file.path.bytes), size: file.size, modificationTime: file.modificationTime, done: ByteRangeSet())
        var resuming = false
        if let saved = PartState.load(statePath), saved.matches(file), fm.fileExists(atPath: partPath) {
            state = saved
            resuming = true
            let have = saved.done.byteCount
            if have > 0 {
                events(.fileResumed(file, bytes: have))
                summary.withLock { $0.resumedBytes += have }
            }
        }
        let gaps = state.done.gaps(in: 0..<file.size)
        if resuming, gaps.isEmpty, file.size > 0 {
            // All bytes are on disk; it only needs verifying.
            alreadyComplete.append(FileJob(file: file, finalPath: finalPath, state: state, resuming: true, ranges: 0,
                                           replace: replace))
            continue
        }
        let ranges = TransferPlan.ranges(size: file.size, connections: clients.count, gaps: resuming ? gaps : nil)
        let job = FileJob(file: file, finalPath: finalPath, state: state, resuming: resuming, ranges: ranges.count,
                          replace: replace)
        work += ranges.map { (job, $0) }
    }
    // Same-size files under replaceIfDifferent: hash both copies. Identical is
    // left as is (and verified); different is downloaded again and replaced.
    if let effectiveHasher, !toCompare.isEmpty {
        let differing = await withTaskGroup(of: RemoteFile?.self) { group in
            for (file, finalPath) in toCompare {
                group.addTask {
                    do {
                        async let local = Task.detached { try localSHA256(path: finalPath) }.value
                        let remote = try await hashLimiter.run { try await effectiveHasher.sha256(file.path) }
                        if try await local == remote.sha256 {
                            events(.fileFinished(file, verification: .alreadyPresentVerified(remote.sha256)))
                            summary.withLock { $0.finished.append(file) }
                            return nil
                        }
                        return file
                    } catch {
                        events(.fileFailed(file, "couldn't compare with the existing copy: \(error)"))
                        summary.withLock { $0.failed.append((file, "\(error)")) }
                        return nil
                    }
                }
            }
            var result: [RemoteFile] = []
            for await file in group { if let file { result.append(file) } }
            return result
        }
        for file in differing {
            let finalPath = directory + "/" + file.relativePath
            let state = PartState(remotePath: Data(file.path.bytes), size: file.size, modificationTime: file.modificationTime,
                                  done: ByteRangeSet())
            let ranges = TransferPlan.ranges(size: file.size, connections: clients.count, gaps: nil)
            let job = FileJob(file: file, finalPath: finalPath, state: state, resuming: false, ranges: ranges.count, replace: true)
            work += ranges.map { (job, $0) }
        }
    }
    let queue = WorkQueue(work)

    let record: @Sendable (FileJob, String) async -> Void = { job, reason in
        if await job.fail(reason) {
            events(.fileFailed(job.file, reason))
            summary.withLock { $0.failed.append((job.file, reason)) }
        }
    }
    let startHash: @Sendable (FileJob) async -> Void = { job in
        guard let effectiveHasher else { return }
        let path = job.file.path
        let file = job.file
        await job.startRemoteHash {
            try await hashLimiter.run {
                try await effectiveHasher.sha256(path) { bytes in events(.fileHashProgress(file, bytes: bytes)) }
            }
        }
    }

    for job in alreadyComplete {
        do {
            let part = try PartFile.reopen(at: await job.partPath, size: job.file.size)
            await startHash(job)
            finishedSink.yield((job, part))
        } catch {
            await record(job, "\(error)")
        }
    }

    await withTaskGroup(of: Void.self) { group in
        // One worker per connection, all pulling from the same queue.
        group.addTask {
            await withTaskGroup(of: Void.self) { workers in
                for (index, client) in clients.enumerated() {
                    let connectionCounter = connectionCounters.flatMap { index < $0.count ? $0[index] : nil }
                    let progress: @Sendable (Int) -> Void = { n in
                        counter.add(n)
                        connectionCounter?.add(n)
                    }
                    workers.addTask {
                        while let (job, range) = await queue.next() {
                            // The server starts hashing when the first range is handed out,
                            // so it reads the file while the download does.
                            if await job.assigned() { await startHash(job) }
                            var succeeded = false
                            if await job.failure == nil {
                                do {
                                    if !(await job.hasStarted) {
                                        // Stability gate (PRD R3.9): the file must still match the
                                        // listing, checked before a part file is created, so a file
                                        // still being written doesn't leave a preallocated part.
                                        let now = try await client.stat(job.file.path)
                                        guard now.size == job.file.size, now.modificationTime == job.file.modificationTime else {
                                            throw SFTPError.unexpected("changed since it was listed (still being written?); will re-list")
                                        }
                                    }
                                    let (part, first) = try await job.begin()
                                    if first { events(.fileStarted(job.file)) }
                                    let stats = try await client.download(job.file.path, range: range, into: part,
                                                                          progress: progress)
                                    if stats.endedEarly {
                                        throw SFTPError.unexpected("file is shorter than listed (changed on the server?)")
                                    }
                                    succeeded = true
                                } catch {
                                    await record(job, "\(error)")
                                }
                            }
                            if let complete = await job.rangeEnded(range, succeeded: succeeded) {
                                events(.fileDownloaded(job.file))
                                finishedSink.yield((job, complete))
                            }
                        }
                    }
                }
            }
            finishedSink.finish()
        }

        // Verifiers: sync, compare checksums, set the modification time, rename.
        group.addTask {
            await withTaskGroup(of: Void.self) { verifiers in
                for await (job, part) in finished {
                    verifiers.addTask {
                        do {
                            let verification = try await finalize(job: job, part: part, hasher: effectiveHasher,
                                                                  overwrite: options.overwrite || job.replace)
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

private func finalize(job: FileJob, part: PartFile, hasher: RemoteHasher?, overwrite: Bool) async throws -> Verification {
    let verify = hasher != nil
    try part.sync()
    part.close()
    let file = job.file
    let partPath = await job.partPath
    let statePath = await job.statePath
    let finalPath = job.finalPath

    var verification = Verification.skipped
    if verify, let remoteHash = await job.remoteHash {
        async let local = Task.detached { try localSHA256(path: partPath) }.value
        let remote: RemoteHasher.Result
        do {
            var result = try await remoteHash.value
            // A cached server hash that disagrees gets one fresh computation: the
            // cache may predate a change the key didn't catch.
            if result.cached, let hasher, let mine = try? await local, mine != result.sha256 {
                result = try await hasher.sha256(file.path, bypassCache: true)
            }
            remote = result
        } catch let unavailable as RemoteHasher.Unavailable {
            // The server can't hash at all (no shell access, no sha256sum): fall
            // back to a size check and say so (PRD R4.1).
            _ = try? await local
            remote = RemoteHasher.Result(sha256: "", size: nil, modificationTime: nil, cached: false)
            verification = .sizeOnly(reason: unavailable.reason)
        } catch {
            // Interrupted (connection lost, Blit quitting): never accept the file
            // unverified. Keep the complete part file; a retry or the next
            // launch hashes it again (PRD R4.1, R3.6).
            _ = try? await local
            throw SFTPError.unexpected("verification interrupted (\(error)); kept \(partPath)")
        }
        if !remote.sha256.isEmpty {
            if let size = remote.size, let mtime = remote.modificationTime,
               size != file.size || (file.modificationTime != nil && mtime != file.modificationTime) {
                try? FileManager.default.removeItem(atPath: statePath)
                throw SFTPError.unexpected("changed on the server during download; kept \(partPath)")
            }
            let mine = try await local
            guard mine == remote.sha256 else {
                // Don't resume a complete-but-wrong file; the next run starts over.
                try? FileManager.default.removeItem(atPath: statePath)
                throw SFTPError.unexpected("SHA-256 mismatch: local \(mine), server \(remote.sha256); kept \(partPath)")
            }
            verification = .sha256(mine, cached: remote.cached)
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
    try renameIntoPlace(partPath, finalPath, overwrite: overwrite)
    try? FileManager.default.removeItem(atPath: statePath)
    return verification
}
