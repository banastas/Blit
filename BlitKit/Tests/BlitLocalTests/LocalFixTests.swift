// Regression tests for the local copy engine's safety fixes: symlinks and
// empty folders survive a copy (PRD R3.1), a source that changes mid-copy
// fails (as R3.9 for downloads), a file appearing at the destination is never
// replaced by the finishing rename, the space preflight doesn't count clones
// (PRD R5.8), and a failed clone falls back to a real copy (PRD R3.8).

import Darwin
import Foundation
import Synchronization
import Testing

@testable import BlitLocal
@testable import BlitRemote

@Suite struct LocalTreeStructureTests {
    func makeTree() throws -> URL {
        let root = try tempDir("tree").appendingPathComponent("Pack")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("Empty"), withIntermediateDirectories: true)
        try randomData(1_000).write(to: root.appendingPathComponent("a.bin"))
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("Sub/link").path, withDestinationPath: "../a.bin")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("dead").path, withDestinationPath: "missing/awol")
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("dirlink").path, withDestinationPath: "Sub")
        return root
    }

    @Test func walkKeepsSymlinksAndEmptyFoldersAndRecreatesThem() async throws {
        let root = try makeTree()
        let dest = try tempDir("dst")
        defer {
            try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: dest)
        }
        let tree = try localTree(at: root.path)
        #expect(tree.files.map(\.relativePath) == ["Pack/a.bin"])
        #expect(Set(tree.directories) == ["Pack", "Pack/Sub", "Pack/Empty"])
        // Targets verbatim (relative stays relative, broken stays broken), links not followed.
        let links = Dictionary(uniqueKeysWithValues: tree.symlinks.map { ($0.relativePath, $0.target) })
        #expect(links == ["Pack/Sub/link": "../a.bin", "Pack/dead": "missing/awol", "Pack/dirlink": "Sub"])
        #expect(tree.skipped.isEmpty)

        let problems = recreateStructure(directories: tree.directories, symlinks: tree.symlinks, into: dest.path)
        #expect(problems.isEmpty)
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Pack/Empty").path, isDirectory: &isDirectory))
        #expect(isDirectory.boolValue)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dest.appendingPathComponent("Pack/Sub/link").path) == "../a.bin")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dest.appendingPathComponent("Pack/dead").path) == "missing/awol")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dest.appendingPathComponent("Pack/dirlink").path) == "Sub")
        // Recreating over what's already there is idempotent.
        #expect(recreateStructure(directories: tree.directories, symlinks: tree.symlinks, into: dest.path).isEmpty)
    }

    @Test func walkDoesNotFollowDirectorySymlinks() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let tree = try localTree(at: root.path)
        #expect(!tree.files.contains { $0.relativePath.hasPrefix("Pack/dirlink/") })
        #expect(!tree.directories.contains { $0.hasPrefix("Pack/dirlink") })
    }

    @Test func uncopyableItemsAreReportedNotSilentlyDropped() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        guard mkfifo(root.appendingPathComponent("pipe.fifo").path, 0o644) == 0 else {
            throw POSIXFailure("mkfifo")
        }
        let tree = try localTree(at: root.path)
        #expect(tree.skipped.map(\.relativePath) == ["Pack/pipe.fifo"])
        #expect(!tree.files.contains { $0.relativePath == "Pack/pipe.fifo" })
    }
}

@Suite struct CopySafetyTests {
    /// A source that changed between listing and copy fails the file
    /// (still being written; as R3.9 for downloads).
    @Test func sourceChangedSinceListingFailsTheFile() async throws {
        let source = try tempDir("src")
        let dest = try tempDir("dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        let path = source.appendingPathComponent("growing.bin")
        try randomData(300_000).write(to: path)
        let files = try localFiles(at: path.path)
        // The "export" writes more after the listing.
        let handle = try FileHandle(forWritingTo: path)
        try handle.seekToEnd()
        try handle.write(contentsOf: randomData(10_000))
        try handle.close()

        var options = CopyOptions()
        options.allowClone = false
        let summary = try await copy(files, into: dest.path, nas: nil, options: options, counter: ByteCounter()) { _ in }
        #expect(summary.finished.isEmpty)
        #expect(summary.failed.count == 1)
        #expect(summary.failed.first?.reason.contains("changed while it was copied") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)   // no part, no final
    }

    /// A file that appears at the destination after planning is never replaced
    /// by the finishing rename; the copy fails instead.
    @Test func fileAppearingAtTheDestinationMidCopyIsNotReplaced() async throws {
        let source = try tempDir("src")
        let dest = try tempDir("dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        let path = source.appendingPathComponent("late.bin")
        try randomData(200_000).write(to: path)
        let files = try localFiles(at: path.path)
        let interloper = Data("someone else's file".utf8)
        let final = dest.appendingPathComponent("late.bin")

        var options = CopyOptions()
        options.allowClone = false
        options.concurrentFiles = 1
        let summary = try await copy(files, into: dest.path, nas: nil, options: options, counter: ByteCounter()) { event in
            // After the plan's exists check, before the rename.
            if case .fileCopied = event { try? interloper.write(to: final) }
        }
        #expect(summary.failed.count == 1)
        #expect(summary.failed.first?.reason.contains("appeared at the destination") == true)
        #expect(try Data(contentsOf: final) == interloper)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path) == ["late.bin"])   // part cleaned up
    }

    /// Files that will be clones take no new space, so the preflight must not
    /// count them (PRD R5.8, R3.8).
    @Test func spacePreflightDoesNotCountCloneableFiles() async throws {
        let source = try tempDir("src")
        let dest = try tempDir("dst")
        defer {
            try? FileManager.default.removeItem(at: source)
            try? FileManager.default.removeItem(at: dest)
        }
        let path = source.appendingPathComponent("big.bin")
        let data = randomData(100_000)
        try data.write(to: path)
        // Same volume, so it clones — even claiming more bytes than are free.
        let claimed = LocalFile(path: path.path, relativePath: "big.bin", size: 1 << 60, modificationTime: nil)
        final class Seen: @unchecked Sendable { var verifications: [CopyVerification] = []; let lock = NSLock() }
        let seen = Seen()
        let summary = try await copy([claimed], into: dest.path, nas: nil, counter: ByteCounter()) { event in
            if case .fileFinished(_, let v) = event { seen.lock.lock(); seen.verifications.append(v); seen.lock.unlock() }
        }
        #expect(summary.failed.isEmpty)
        #expect(seen.verifications == [.cloned])
        #expect(try Data(contentsOf: dest.appendingPathComponent("big.bin")) == data)
    }

    /// On a volume that can't clone (HFS+ here; SMB and exFAT in the field),
    /// the same-volume branch must fall through to a real copy (PRD R3.8).
    @Test func cloneFallsBackToARealCopyWhereTheVolumeCannotClone() async throws {
        guard let volume = try HFSVolume.attach() else { return }   // hdiutil unavailable in this environment
        defer { volume.detach() }
        let path = volume.mountPoint.appendingPathComponent("a.bin")
        let data = randomData(300_000)
        try data.write(to: path)
        let dest = volume.mountPoint.appendingPathComponent("out")
        final class Seen: @unchecked Sendable { var verifications: [CopyVerification] = []; let lock = NSLock() }
        let seen = Seen()
        let summary = try await copy(try localFiles(at: path.path), into: dest.path, nas: nil, counter: ByteCounter()) { event in
            if case .fileFinished(_, let v) = event { seen.lock.lock(); seen.verifications.append(v); seen.lock.unlock() }
        }
        #expect(summary.failed.isEmpty)
        #expect(summary.finished.count == 1)
        if case .readBack = seen.verifications.first {} else {
            Issue.record("expected a read-back-verified stream copy, got \(seen.verifications)")
        }
        #expect(try Data(contentsOf: dest.appendingPathComponent("a.bin")) == data)
    }
}

/// A small HFS+ disk image, for exercising volumes that can't clonefile.
struct HFSVolume {
    let mountPoint: URL
    let image: URL

    static func attach() throws -> HFSVolume? {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: "/usr/bin/hdiutil") else { return nil }
        let dir = try tempDir("hfs")
        let image = dir.appendingPathComponent("volume.dmg")
        guard run("/usr/bin/hdiutil", ["create", "-size", "16m", "-fs", "HFS+", "-volname", "BlitCloneTest",
                                       "-quiet", image.path]) != nil else { return nil }
        guard let plist = run("/usr/bin/hdiutil", ["attach", "-plist", "-nobrowse", "-mountrandom", dir.path, image.path]),
              let parsed = try? PropertyListSerialization.propertyList(from: plist, format: nil) as? [String: Any],
              let entries = parsed["system-entities"] as? [[String: Any]],
              let mount = entries.compactMap({ $0["mount-point"] as? String }).first
        else { return nil }
        return HFSVolume(mountPoint: URL(fileURLWithPath: mount), image: image)
    }

    func detach() {
        _ = Self.run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-quiet"])
        try? FileManager.default.removeItem(at: image.deletingLastPathComponent())
    }

    /// stdout on success, nil on any failure.
    private static func run(_ tool: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }
}
