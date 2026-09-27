import CryptoKit
import Foundation
import Synchronization
import Testing

@testable import BlitLocal
@testable import BlitRemote

func tempDir(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("blit-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func randomData(_ count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    for i in stride(from: 0, to: count, by: 8) {
        var r = UInt64.random(in: .min ... .max)
        withUnsafeBytes(of: &r) { raw in
            for j in 0..<min(8, count - i) { bytes[i + j] = raw[j] }
        }
    }
    return Data(bytes)
}

func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

@Suite struct StreamCopyTests {
    @Test func copiesAcrossBlockBoundariesAndHashesTheSource() throws {
        let dir = try tempDir("stream")
        defer { try? FileManager.default.removeItem(at: dir) }
        for size in [0, 1, StreamCopy.blockSize - 1, StreamCopy.blockSize, 2 * StreamCopy.blockSize + 12_345] {
            let data = randomData(size)
            let src = dir.appendingPathComponent("src-\(size)")
            let dst = dir.appendingPathComponent("dst-\(size)")
            try data.write(to: src)
            let counter = ByteCounter()
            let hash = try StreamCopy.copy(from: src.path, to: dst.path, progress: counter.add)
            #expect(hash == sha256(data))
            #expect(try Data(contentsOf: dst) == data)
            #expect(counter.total == size)
            #expect(try readBackSHA256(path: dst.path) == hash)
        }
    }
}

@Suite struct LocalCopySessionTests {
    func makeSource() throws -> (URL, [String: Data]) {
        let root = try tempDir("src").appendingPathComponent("Pack")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sub [1]"), withIntermediateDirectories: true)
        var files: [String: Data] = [:]
        for (name, size) in [("a (1).cbz", 300_000), ("Sub [1]/big.mkv", 20_000_000), ("Sub [1]/empty.nfo", 0)] {
            let data = randomData(size)
            try data.write(to: root.appendingPathComponent(name))
            files["Pack/" + name] = data
        }
        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        try Data().write(to: root.appendingPathComponent("stale.mkv.blitpart"))
        return (root, files)
    }

    @Test func copiesFolderVerifiesAndPreservesTimes() async throws {
        let (source, expected) = try makeSource()
        let dest = try tempDir("dst")
        defer {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: dest)
        }
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: source.appendingPathComponent("a (1).cbz").path)

        let files = try localFiles(at: source.path)
        #expect(Set(files.map(\.relativePath)) == Set(expected.keys))   // .DS_Store and .blitpart skipped

        var options = CopyOptions()
        options.allowClone = false
        let counter = ByteCounter()
        let summary = try await copy(files, into: dest.path, nas: nil, options: options, counter: counter) { _ in }
        #expect(summary.failed.isEmpty)
        #expect(summary.finished.count == 3)
        for (relative, data) in expected {
            let copied = dest.appendingPathComponent(relative)
            #expect(try Data(contentsOf: copied) == data)
            #expect(!FileManager.default.fileExists(atPath: copied.path + ".blitpart"))
        }
        let copiedTime = try FileManager.default.attributesOfItem(atPath: dest.appendingPathComponent("Pack/a (1).cbz").path)[.modificationDate] as? Date
        #expect(copiedTime == mtime)
        #expect(counter.total == expected.values.reduce(0) { $0 + $1.count })
    }

    /// A copy can't resume, so a stopped or failed one removes its part file.
    @Test func stoppedCopyLeavesNoPartFile() async throws {
        let (source, _) = try makeSource()
        let dest = try tempDir("dst")
        defer {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: dest)
        }
        let files = try localFiles(at: source.path).filter { $0.relativePath.hasSuffix("big.mkv") }
        let started = Mutex(false)
        var options = CopyOptions()
        options.allowClone = false
        options.concurrentFiles = 1
        options.shouldStop = { started.withLock { $0 } }
        let summary = try await copy(files, into: dest.path, nas: nil, options: options, counter: ByteCounter()) { event in
            if case .fileStarted = event { started.withLock { $0 = true } }
        }
        #expect(summary.failed.count == 1)
        let left = (try FileManager.default.subpathsOfDirectory(atPath: dest.path)).filter { $0.hasSuffix(".blitpart") }
        #expect(left.isEmpty)
    }

    @Test func refusesExistingFilesUnlessOverwriting() async throws {
        let (source, _) = try makeSource()
        let dest = try tempDir("dst")
        defer {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: dest)
        }
        let files = try localFiles(at: source.path)
        var options = CopyOptions()
        options.allowClone = false
        _ = try await copy(files, into: dest.path, nas: nil, options: options, counter: ByteCounter()) { _ in }
        let again = try await copy(files, into: dest.path, nas: nil, options: options, counter: ByteCounter()) { _ in }
        #expect(again.failed.count == 3)
        options.overwrite = true
        let replaced = try await copy(files, into: dest.path, nas: nil, options: options, counter: ByteCounter()) { _ in }
        #expect(replaced.failed.isEmpty)
    }

    @Test func skipsIdenticalExistingFilesWhenAsked() async throws {
        let (source, _) = try makeSource()
        let dest = try tempDir("dst")
        defer {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: dest)
        }
        let files = try localFiles(at: source.path)
        var options = CopyOptions()
        options.allowClone = false
        _ = try await copy(files, into: dest.path, nas: nil, options: options, counter: ByteCounter()) { _ in }
        options.skipExistingSameSize = true
        final class Seen: @unchecked Sendable { var v: [CopyVerification] = []; let lock = NSLock() }
        let seen = Seen()
        let counter = ByteCounter()
        let again = try await copy(files, into: dest.path, nas: nil, options: options, counter: counter) { event in
            if case .fileFinished(_, let v) = event { seen.lock.lock(); seen.v.append(v); seen.lock.unlock() }
        }
        #expect(again.failed.isEmpty)
        #expect(again.finished.count == 3)
        #expect(seen.v.allSatisfy { $0 == .alreadyPresent })
        #expect(counter.total == 0)
    }

    @Test func clonesWithinOneVolume() async throws {
        let (source, _) = try makeSource()
        let dest = try tempDir("dst")
        defer {
            try? FileManager.default.removeItem(at: source.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: dest)
        }
        final class Seen: @unchecked Sendable { var verifications: [CopyVerification] = []; let lock = NSLock() }
        let seen = Seen()
        let summary = try await copy(try localFiles(at: source.path), into: dest.path, nas: nil, counter: ByteCounter()) { event in
            if case .fileFinished(_, let v) = event { seen.lock.lock(); seen.verifications.append(v); seen.lock.unlock() }
        }
        #expect(summary.failed.isEmpty)
        #expect(seen.verifications.allSatisfy { $0 == .cloned })
    }

    @Test func failsBeforeWritingWhenSpaceIsShort() async throws {
        let dest = try tempDir("dst")
        defer { try? FileManager.default.removeItem(at: dest) }
        let huge = LocalFile(path: "/dev/null", relativePath: "huge.bin", size: 1 << 60, modificationTime: nil)
        await #expect(throws: CopyPreflightError.self) {
            _ = try await copy([huge], into: dest.path, nas: nil, counter: ByteCounter()) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
    }
}

@Suite struct NASMappingTests {
    @Test func mapsMountPathsToTheNAS() {
        #expect(NASVerifier.map("/Volumes/Media/Movies/a.mkv.blitpart", mountPoint: "/Volumes/Media", nasRoot: "/volume1/Media")
                == "/volume1/Media/Movies/a.mkv.blitpart")
        #expect(NASVerifier.map("/Volumes/Media", mountPoint: "/Volumes/Media/", nasRoot: "/volume1/Media") == "/volume1/Media")
        #expect(NASVerifier.map("/Volumes/MediaX/a", mountPoint: "/Volumes/Media", nasRoot: "/volume1/Media") == nil)
    }

    @Test func mountInfoForTheBootVolume() throws {
        let info = try #require(MountInfo.of("/"))
        #expect(info.mountPoint == "/")
        #expect(!info.isSMB)
        #expect(MountInfo(mountPoint: "/Volumes/Media", source: "//u@d1ll1N9eR._smb._tcp.local/Media", fileSystem: "smbfs").shareName == "Media")
    }

    @Test func networkPathIgnoresLoopback() {
        #expect(NetworkPath.to(host: "127.0.0.1") == nil)
        #expect(NetworkPath.ipv4("localhost") != nil)
    }
}

/// The mount table lookups agree with statfs, without touching the volume.
struct MountTableTests {
    @Test func containingMatchesStatfs() {
        // Same file system and SMB-ness as statfs (the startup disk's firmlinked
        // Data volume reports "/" by path; see containing(_:)).
        for path in ["/", NSHomeDirectory(), FileManager.default.temporaryDirectory.path] {
            #expect(MountInfo.containing(path)?.fileSystem == MountInfo.of(path)?.fileSystem, "\(path)")
            #expect(MountInfo.containing(path)?.isSMB == MountInfo.of(path)?.isSMB, "\(path)")
        }
        // Mounted volumes (drives, SMB shares) match exactly.
        for volume in (try? FileManager.default.contentsOfDirectory(atPath: "/Volumes")) ?? [] {
            let path = "/Volumes/" + volume
            guard let real = MountInfo.of(path), real.mountPoint == path else { continue }
            #expect(MountInfo.containing(path + "/x")?.mountPoint == path)
            #expect(MountInfo.mounted(at: path)?.source == real.source)
        }
        #expect(MountInfo.mounted(at: "/")?.mountPoint == "/")
        #expect(MountInfo.mounted(at: "/Volumes/BlitNoSuchVolume") == nil)
        #expect(!MountInfo.all().isEmpty)
    }
}
