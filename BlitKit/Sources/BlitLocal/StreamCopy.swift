// Copies one file between local volumes (including SMB mounts): 8 MB blocks,
// reads and writes overlapped, SHA-256 computed as the data streams so the
// source is read only once (PRD R3.7, R4.2).

import CryptoKit
import Darwin
import Foundation
import BlitRemote

enum StreamCopy {
    static let blockSize = 8 << 20
    /// Blocks allowed between the reader and the writer.
    static let depth = 3
    #if DEBUG
    /// Test copies only (`-BlitDebugCopyMBps`): a slower pace, so a test can
    /// act on a file while it's being copied.
    static let debugPace = UserDefaults.standard.double(forKey: "BlitDebugCopyMBps")
    #endif

    /// Copies `source` to `destination` (created or truncated) and returns the
    /// source's SHA-256. Blocking; call from a thread that may block.
    /// Stopped copies throw this (the part file is left for the caller).
    public struct Stopped: Error, CustomStringConvertible, Sendable {
        public var description: String { "stopped" }
    }

    static func copy(from source: String, to destination: String, progress: @escaping @Sendable (Int) -> Void,
                     shouldStop: (@Sendable () -> Bool)? = nil) throws -> String {
        let src = Darwin.open(source, O_RDONLY | O_CLOEXEC)
        guard src >= 0 else { throw POSIXFailure("open \(source)") }
        defer { Darwin.close(src) }
        var info = Darwin.stat()
        guard fstat(src, &info) == 0 else { throw POSIXFailure("stat \(source)") }
        let size = UInt64(info.st_size)
        _ = fcntl(src, F_NOCACHE, 1)
        _ = fcntl(src, F_RDAHEAD, 1)

        let dst = Darwin.open(destination, O_CREAT | O_WRONLY | O_TRUNC | O_CLOEXEC, 0o644)
        guard dst >= 0 else { throw POSIXFailure("create \(destination)") }
        defer { Darwin.close(dst) }
        _ = fcntl(dst, F_NOCACHE, 1)
        if size > 0 {
            // Reserve space up front on local volumes; SMB usually refuses, which is fine.
            var store = fstore_t(fst_flags: UInt32(F_ALLOCATEALL), fst_posmode: F_PEOFPOSMODE,
                                 fst_offset: 0, fst_length: off_t(size), fst_bytesalloc: 0)
            _ = fcntl(dst, F_PREALLOCATE, &store)
        }

        let pipeline = Pipeline(fd: dst, blockSize: blockSize, depth: depth)
        defer { pipeline.deallocate() }
        var hasher = SHA256()
        var offset: off_t = 0
        var block = 0
        while true {
            pipeline.free.wait()
            if let error = pipeline.error { pipeline.free.signal(); throw error }
            let buffer = pipeline.buffers[block % depth]
            var n = 0
            repeat { n = read(src, buffer.baseAddress, blockSize) } while n < 0 && errno == EINTR
            if n < 0 { pipeline.free.signal(); pipeline.drain(); throw POSIXFailure("read \(source)") }
            if n == 0 { pipeline.free.signal(); break }
            if shouldStop?() == true { pipeline.free.signal(); pipeline.drain(); throw Stopped() }
            hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<n]))
            pipeline.write(buffer: block % depth, count: n, at: offset, progress: progress)
            offset += off_t(n)
            block += 1
            #if DEBUG
            if debugPace > 0 { usleep(useconds_t(Double(n) / debugPace)) }   // bytes ÷ (MB/s) = µs
            #endif
        }
        pipeline.drain()
        if let error = pipeline.error { throw error }
        // Local volumes: F_FULLFSYNC; SMB doesn't support it, so fall back to fsync (PRD R3.5).
        if fcntl(dst, F_FULLFSYNC) != 0, fsync(dst) != 0 { throw POSIXFailure("sync \(destination)") }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Reader-to-writer handoff: a serial write queue and a semaphore of free
    /// buffers. Writes complete in order, so when a buffer slot is free again
    /// its previous write has finished.
    final class Pipeline: @unchecked Sendable {
        let fd: Int32
        let buffers: [UnsafeMutableRawBufferPointer]
        let free: DispatchSemaphore
        private let queue = DispatchQueue(label: "blit.copy.write")
        private let group = DispatchGroup()
        private let lock = NSLock()
        private var firstError: Error?

        init(fd: Int32, blockSize: Int, depth: Int) {
            self.fd = fd
            buffers = (0..<depth).map { _ in UnsafeMutableRawBufferPointer.allocate(byteCount: blockSize, alignment: 16384) }
            free = DispatchSemaphore(value: depth)
        }

        var error: Error? {
            lock.lock()
            defer { lock.unlock() }
            return firstError
        }

        func write(buffer index: Int, count: Int, at offset: off_t, progress: @escaping @Sendable (Int) -> Void) {
            let fd = self.fd
            group.enter()
            queue.async { [self] in
                defer { free.signal(); group.leave() }
                guard error == nil else { return }
                let buffer = buffers[index]
                var done = 0
                while done < count {
                    let n = pwrite(fd, buffer.baseAddress! + done, count - done, offset + off_t(done))
                    if n < 0 {
                        if errno == EINTR { continue }
                        lock.lock()
                        if firstError == nil { firstError = POSIXFailure("write") }
                        lock.unlock()
                        return
                    }
                    done += n
                }
                progress(count)
            }
        }

        func drain() { group.wait() }

        func deallocate() {
            drain()
            buffers.forEach { $0.deallocate() }
        }
    }
}

/// SHA-256 of a file read with the cache bypassed where possible. A weaker check
/// than hashing on the NAS: an SMB client can still answer from its own cache.
/// `progress` gets the bytes read so far, about every 64 MB.
func readBackSHA256(path: String, progress: ((UInt64) -> Void)? = nil,
                    shouldStop: (@Sendable () -> Bool)? = nil) throws -> String {
    let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { throw POSIXFailure("open \(path)") }
    defer { Darwin.close(fd) }
    _ = fcntl(fd, F_NOCACHE, 1)
    var hasher = SHA256()
    let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: StreamCopy.blockSize, alignment: 16384)
    defer { buffer.deallocate() }
    var total: UInt64 = 0, reported: UInt64 = 0
    while true {
        // A pause or cancel takes hold here too: reading back a 30 GB copy
        // from a NAS takes minutes, and Pause used to wait for all of it.
        if shouldStop?() == true { throw StreamCopy.Stopped() }
        let n = read(fd, buffer.baseAddress, StreamCopy.blockSize)
        if n < 0 {
            if errno == EINTR { continue }
            throw POSIXFailure("read \(path)")
        }
        if n == 0 { break }
        hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: buffer[..<n]))
        total += UInt64(n)
        if let progress, total - reported >= 64 << 20 {
            progress(total)
            reported = total
        }
    }
    progress?(total)
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
