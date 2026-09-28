import Foundation
import Testing

@testable import BlitRemote
@testable import BlitSFTP

/// The forget script must drop exactly the cache entry the hash script would
/// serve, so a stale or poisoned hash is never returned twice (PRD R4.1).
@Suite struct ForgetCachedHashTests {
    @Test func forgetScriptHasNoSingleQuotes() {
        #expect(!RemoteHasher.forgetScript.contains("'"))
    }

    /// Runs the real scripts under /bin/sh with a GNU-style `stat -c` shim
    /// (macOS stat uses -f): hash, hit the cache, forget, recompute.
    @Test func forgetRemovesTheServedCacheEntry() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("blit-forget-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let shim = bin.appendingPathComponent("stat")
        try "#!/bin/sh\n# GNU-style: stat -L -c \"%s %Y %Z %i\" -- FILE\nexec /usr/bin/stat -L -f \"%z %m %c %i\" \"$5\"\n"
            .write(to: shim, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)

        let file = root.appendingPathComponent("it's a \"quoted\" name.bin")
        try Data("abcdef".utf8).write(to: file)
        #expect(try run(RemoteHasher.script, on: file, bin: bin, home: root)?.cached == false)
        #expect(try run(RemoteHasher.script, on: file, bin: bin, home: root)?.cached == true)

        // Poisoned entry under the same key: served until forgotten.
        let cache = root.appendingPathComponent(".cache/blit/sha256")
        let entries = try fm.contentsOfDirectory(atPath: cache.path)
        #expect(entries.count == 1)
        let bad = String(repeating: "0", count: 64)
        try (bad + "\n").write(to: cache.appendingPathComponent(entries[0]), atomically: true, encoding: .utf8)
        #expect(try run(RemoteHasher.script, on: file, bin: bin, home: root)?.sha256 == bad)

        _ = try run(RemoteHasher.forgetScript, on: file, bin: bin, home: root)
        #expect(try fm.contentsOfDirectory(atPath: cache.path).isEmpty)
        let recomputed = try #require(try run(RemoteHasher.script, on: file, bin: bin, home: root))
        #expect(!recomputed.cached)
        #expect(recomputed.sha256 == "bef57ec7f53a6d40beb640a780a639c83bc29ac8a9816f1fc6c5c6dcd93c4721")

        // A path that can't be stat-ed (or was never hashed) is a quiet no-op.
        _ = try run(RemoteHasher.forgetScript, on: root.appendingPathComponent("gone.bin"), bin: bin, home: root)
    }

    private func run(_ script: String, on file: URL, bin: URL, home: URL) throws -> RemoteHasher.Result? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "blit", file.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOME"] = home.path
        env.removeValue(forKey: "XDG_CACHE_HOME")
        env.removeValue(forKey: "BLIT_NOCACHE")
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return RemoteHasher.parse(scriptOutput: Array(out.fileHandleForReading.readDataToEndOfFile()))
    }
}

/// Repeated SHA-256 mismatches are counted in the sidecar, so a hash that
/// never matches can't re-download the file forever (PRD R4.3).
@Suite struct MismatchCounterTests {
    @Test func mismatchCountSurvivesTheSidecar() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("a.mkv.blitpart.state").path
        var state = PartState(remotePath: Data("/home/u/a.mkv".utf8), size: 1000, modificationTime: 5,
                              done: ByteRangeSet([0..<1000]),
                              source: SSHEndpoint(host: "box.example", port: 22, username: "u"))
        try state.save(path)
        #expect(PartState.load(path)?.sha256Mismatches == nil)

        // What finalize does on a mismatch: clear the ranges, count the strike.
        state.done = ByteRangeSet()
        state.sha256Mismatches = 1
        try state.save(path)
        let reloaded = try #require(PartState.load(path))
        #expect(reloaded.sha256Mismatches == 1)
        #expect(reloaded.done.byteCount == 0)
        #expect(reloaded.done.gaps(in: 0..<1000) == [0..<1000])
        // Still the same remote file: the next attempt resumes (and re-downloads).
        let file = RemoteFile(path: RemotePath("/home/u/a.mkv"), relativePath: "a.mkv", size: 1000, modificationTime: 5)
        #expect(reloaded.matches(file))

        // A sidecar from before the counter existed still decodes.
        var old = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as! [String: Any]
        old.removeValue(forKey: "sha256Mismatches")
        try JSONSerialization.data(withJSONObject: old).write(to: URL(fileURLWithPath: path))
        #expect(try #require(PartState.load(path)).sha256Mismatches == nil)
    }

    @Test func thirdMismatchIsTerminal() {
        // finalize gives up when the counter reaches the cap.
        #expect(PartState.maxSHA256Mismatches == 3)
        let strikes = [nil, 1, 2].map { ($0 ?? 0) + 1 >= PartState.maxSHA256Mismatches }
        #expect(strikes == [false, false, true])
    }
}
