// Regression tests for the security audit's Blit leads: writes never follow a
// symlink in the destination tree (one recreated from a copy source, or
// planted at a part file's name), and copies keep the source's quarantine mark.

import Darwin
import Foundation
import Testing

@testable import BlitLocal
@testable import BlitRemote

@Suite struct DestinationSymlinkTests {
    /// The audit's two-step case: a share's link is recreated at the destination,
    /// then a later copy of the same tree has a real folder there.
    @Test func copyNeverWritesThroughARecreatedLink() async throws {
        let root = try tempDir("escape")
        let fm = FileManager.default
        let outside = root.appendingPathComponent("outside")
        let dest = root.appendingPathComponent("dest")
        let first = root.appendingPathComponent("first/Show")
        for folder in [outside, dest, first] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try fm.createSymbolicLink(atPath: first.appendingPathComponent("S1").path, withDestinationPath: "../../outside")

        let linkTree = try localTree(at: first.path)
        #expect(recreateStructure(directories: linkTree.directories, symlinks: linkTree.symlinks, into: dest.path).isEmpty)
        #expect(try fm.destinationOfSymbolicLink(atPath: dest.appendingPathComponent("Show/S1").path) == "../../outside")

        let second = root.appendingPathComponent("second/Show")
        try fm.createDirectory(at: second.appendingPathComponent("S1"), withIntermediateDirectories: true)
        try randomData(4096).write(to: second.appendingPathComponent("S1/a.txt"))
        let fileTree = try localTree(at: second.path)

        for clone in [false, true] {
            var options = CopyOptions()
            options.allowClone = clone
            options.skipExistingSameSize = true
            let summary = try await copy(fileTree.files, into: dest.path, nas: nil, options: options, counter: ByteCounter()) { _ in }
            #expect(summary.finished.isEmpty)
            #expect(summary.failed.count == 1)
            #expect(!fm.fileExists(atPath: outside.appendingPathComponent("a.txt").path))
            #expect(!fm.fileExists(atPath: outside.appendingPathComponent("a.txt.blitpart").path))
        }
        // Recreating the second tree's folders refuses the linked one too.
        #expect(!recreateStructure(directories: fileTree.directories, symlinks: [], into: dest.path).isEmpty)
    }

    @Test func partFileNeverFollowsALinkAtItsName() throws {
        let root = try tempDir("partlink")
        let victim = root.appendingPathComponent("victim.txt")
        try Data("DUMMY".utf8).write(to: victim)
        let part = root.appendingPathComponent("b.txt.blitpart").path
        try FileManager.default.createSymbolicLink(atPath: part, withDestinationPath: victim.path)
        #expect(throws: (any Error).self) { try PartFile.create(at: part, size: 3) }
        #expect(throws: (any Error).self) { try PartFile.reopen(at: part, size: 5) }
        #expect(try Data(contentsOf: victim) == Data("DUMMY".utf8))
    }

    @Test func safePathRefusesLinkedFoldersButAllowsALinkedRoot() throws {
        let root = try tempDir("safepath")
        let fm = FileManager.default
        let outside = root.appendingPathComponent("outside")
        let dest = root.appendingPathComponent("dest")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: dest.appendingPathComponent("Show").path, withDestinationPath: outside.path)

        #expect(throws: SafePath.Escape.self) { try SafePath.createParents(of: dest.path + "/Show/c.txt", under: dest.path) }
        #expect(throws: SafePath.Escape.self) { try SafePath.check(dest.path + "/Show", under: dest.path) }
        try SafePath.createParents(of: dest.path + "/New/Deeper/c.txt", under: dest.path)
        #expect(fm.fileExists(atPath: dest.path + "/New/Deeper"))
        #expect((try? fm.contentsOfDirectory(atPath: outside.path))?.isEmpty == true)

        // The folder the user chose may itself be a link (~/Downloads on another drive).
        let linkedRoot = root.appendingPathComponent("chosen")
        try fm.createSymbolicLink(atPath: linkedRoot.path, withDestinationPath: dest.path)
        try SafePath.createParents(of: linkedRoot.path + "/Fine/x.txt", under: linkedRoot.path)
        #expect(fm.fileExists(atPath: dest.path + "/Fine"))
    }
}

@Suite struct QuarantineCopyTests {
    @Test func streamCopyKeepsTheSourcesQuarantineMark() async throws {
        let root = try tempDir("quarantine")
        let fm = FileManager.default
        let source = root.appendingPathComponent("src/sample.zip")
        try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try randomData(2048).write(to: source)
        let mark = Array("0083;00000000;Safari;".utf8)
        #expect(setxattr(source.path, Quarantine.attribute, mark, mark.count, 0, 0) == 0)

        var options = CopyOptions()
        options.allowClone = false   // a move, or another drive: the streamed path
        let dest = root.appendingPathComponent("dest")
        let summary = try await copy(try localFiles(at: source.path), into: dest.path, nas: nil, options: options,
                                     counter: ByteCounter()) { _ in }
        #expect(summary.failed.isEmpty)
        #expect(Quarantine.isMarked(dest.appendingPathComponent("sample.zip").path))
    }

    @Test func downloadsAreMarked() throws {
        let file = try tempDir("marked").appendingPathComponent("payload.zip")
        try randomData(16).write(to: file)
        #expect(!Quarantine.isMarked(file.path))
        Quarantine.markDownloaded(file.path)
        #expect(Quarantine.isMarked(file.path))
    }
}
