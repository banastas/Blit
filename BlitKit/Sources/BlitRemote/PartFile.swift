// A `.blitpart` destination file: positional writes on a thread pool (off the
// network event loops), preallocation, and a full sync before verification.

import CryptoKit
import Darwin
import NIOCore
import NIOPosix

public final class PartFile: Sendable {
    public let path: String
    let fd: Int32
    let pool: NIOThreadPool

    /// Creates (or truncates) `path` and sizes it to `size`. Never follows a
    /// symlink at `path` (O_NOFOLLOW): a planted `.blitpart` link would
    /// otherwise truncate and overwrite its target.
    public static func create(at path: String, size: UInt64, pool: NIOThreadPool = .singleton) throws -> PartFile {
        guard size <= UInt64(Int64.max) else { throw POSIXFailure("create \(path): size \(size) is too large", code: EFBIG) }
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_TRUNC | O_CLOEXEC | O_NOFOLLOW, 0o644)
        guard fd >= 0 else { throw POSIXFailure("open \(path)") }
        if size > 0 {
            // Reserve the space up front (local volumes; unsupported over SMB, so failure is fine).
            var store = fstore_t(fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE,
                                 fst_offset: 0, fst_length: off_t(size), fst_bytesalloc: 0)
            _ = fcntl(fd, F_PREALLOCATE, &store)
            guard ftruncate(fd, off_t(size)) == 0 else {
                Darwin.close(fd)
                throw POSIXFailure("size \(path)")
            }
        }
        return PartFile(path: path, fd: fd, pool: pool)
    }

    /// Reopens an existing part file for resuming; its size must be `size`.
    public static func reopen(at path: String, size: UInt64, pool: NIOThreadPool = .singleton) throws -> PartFile {
        let fd = Darwin.open(path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXFailure("open \(path)") }
        var info = Darwin.stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, UInt64(info.st_size) == size else {
            Darwin.close(fd)
            throw POSIXFailure("resume \(path): unexpected size")
        }
        return PartFile(path: path, fd: fd, pool: pool)
    }

    private init(path: String, fd: Int32, pool: NIOThreadPool) {
        self.path = path
        self.fd = fd
        self.pool = pool
    }

    /// Writes `buffer` at `offset`; the future completes on `eventLoop`.
    public func write(_ buffer: ByteBuffer, at offset: UInt64, on eventLoop: EventLoop) -> EventLoopFuture<Void> {
        let fd = self.fd
        return pool.runIfActive(eventLoop: eventLoop) {
            try buffer.withUnsafeReadableBytes { raw in
                var done = 0
                while done < raw.count {
                    let n = pwrite(fd, raw.baseAddress! + done, raw.count - done, off_t(offset) + off_t(done))
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw POSIXFailure("write")
                    }
                    done += n
                }
            }
        }
    }

    /// Flushes to stable storage: F_FULLFSYNC on local volumes, fsync where
    /// that isn't supported (SMB), PRD R3.5.
    public func sync() throws {
        if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { throw POSIXFailure("sync") }
    }

    public func close() {
        Darwin.close(fd)
    }
}

public struct POSIXFailure: Error, CustomStringConvertible, Sendable {
    public let operation: String
    public let code: Int32

    public init(_ operation: String) {
        self.operation = operation
        self.code = errno
    }

    public init(_ operation: String, code: Int32) {
        self.operation = operation
        self.code = code
    }

    public var description: String { "\(operation): \(String(cString: strerror(code)))" }
}

/// SHA-256 of a local file, read in 8 MB chunks.
public func localSHA256(path: String) throws -> String {
    let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw POSIXFailure("open \(path)") }
    defer { Darwin.close(fd) }
    var hasher = SHA256()
    let chunk = 8 << 20
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: chunk, alignment: 16)
    defer { buffer.deallocate() }
    while true {
        let n = read(fd, buffer.baseAddress, chunk)
        if n < 0 {
            if errno == EINTR { continue }
            throw POSIXFailure("read \(path)")
        }
        if n == 0 { break }
        hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<n]))
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// Moves a finished part file to its final name. Unless `overwrite`, fails if
/// something now exists there: the exists check at planning time can be hours
/// old, and another writer may have created the file since (RENAME_EXCL where
/// the volume supports it; a check just before the rename elsewhere, e.g. SMB).
public func renameIntoPlace(_ part: String, _ final: String, overwrite: Bool) throws {
    if overwrite {
        guard rename(part, final) == 0 else { throw POSIXFailure("rename to \(final)") }
        return
    }
    if renamex_np(part, final, UInt32(RENAME_EXCL)) == 0 { return }
    let code = errno
    if code == EEXIST {
        throw POSIXFailure("\(final) appeared at the destination during the transfer; kept \(part)", code: code)
    }
    guard code == ENOTSUP || code == EINVAL else { throw POSIXFailure("rename to \(final)", code: code) }
    if access(final, F_OK) == 0 {
        throw POSIXFailure("\(final) appeared at the destination during the transfer; kept \(part)", code: EEXIST)
    }
    guard rename(part, final) == 0 else { throw POSIXFailure("rename to \(final)") }
}
