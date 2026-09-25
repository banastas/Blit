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

    /// Creates (or truncates) `path` and sizes it to `size`.
    public static func create(at path: String, size: UInt64, pool: NIOThreadPool = .singleton) throws -> PartFile {
        let fd = Darwin.open(path, O_CREAT | O_RDWR | O_TRUNC | O_CLOEXEC, 0o644)
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
