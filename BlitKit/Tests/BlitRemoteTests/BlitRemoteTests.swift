import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing

@testable import BlitRemote
@testable import BlitSFTP

// Throwaway keys generated with ssh-keygen; fingerprints are ssh-keygen -lf output.
let ed25519Line = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA+834eh2xNITrcRFc3cvnXS9qyKGMxdrLpOiyMjNVzZ"
let ed25519Fingerprint = "SHA256:CVo5m3PS0Dn9cZqfxGvRBGEJtwkdSRtgXQZt84Lzmec"
let ecdsaLine = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBDyLCFWrXDZ0tk0VskwXmmEG2sYPkfnvHsIY2nvnLIii+c0JVAv2mooSwDlP8yh9MNs9rn6GY2ffgA9gRLulX/Q="
let ecdsaFingerprint = "SHA256:76qoOQkgBMCQb+Pv8st5gk/vAkC3VBxLHcxjifRRDkw"

@Suite struct HostKeyTests {
    @Test func fingerprintsMatchSSHKeygen() throws {
        #expect(HostKeyIdentity(try NIOSSHPublicKey(openSSHPublicKey: ed25519Line)).fingerprint == ed25519Fingerprint)
        let ecdsa = HostKeyIdentity(try NIOSSHPublicKey(openSSHPublicKey: ecdsaLine))
        #expect(ecdsa.fingerprint == ecdsaFingerprint)
        #expect(ecdsa.type == "ecdsa-sha2-nistp256")
    }

    @Test func knownHostsMatchesHostAndPort() throws {
        let text = """
        # comment
        example.com \(ed25519Line)
        [example.com]:2222 \(ecdsaLine)
        other.org,[example.com]:3232 \(ed25519Line) trailing-comment
        |1|hashed=|entry= \(ed25519Line)
        @revoked example.com \(ecdsaLine)
        """
        #expect(KnownHostsVerifier.keys(in: text, host: "example.com", port: 22).count == 1)
        #expect(KnownHostsVerifier.keys(in: text, host: "example.com", port: 2222).map { HostKeyIdentity($0).type } == ["ecdsa-sha2-nistp256"])
        #expect(KnownHostsVerifier.keys(in: text, host: "example.com", port: 3232).count == 1)
        #expect(KnownHostsVerifier.keys(in: text, host: "example.com", port: 4444).isEmpty)
    }

    @Test func rejectionReportsPresentedAndKnownKeys() throws {
        // The SFTPGo case from M1: server presents Ed25519, only ECDSA is on file.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("known_hosts").path
        try "[example.com]:2222 \(ecdsaLine)\n".write(toFile: path, atomically: true, encoding: .utf8)

        let presented = try NIOSSHPublicKey(openSSHPublicKey: ed25519Line)
        let verdict = KnownHostsVerifier(path: path).verify(host: "example.com", port: 2222, key: presented)
        #expect(verdict == .rejected(presented: HostKeyIdentity(presented),
                                     known: [HostKeyIdentity(try NIOSSHPublicKey(openSSHPublicKey: ecdsaLine))]))

        let pinned = KnownHostsVerifier(path: path, pinnedFingerprints: [ed25519Fingerprint])
        #expect(pinned.verify(host: "example.com", port: 2222, key: presented) == .trusted)
    }
}

@Suite struct TransferPlanTests {
    let mb: UInt64 = 1 << 20

    @Test func smallFilesAreOneRange() {
        #expect(TransferPlan.ranges(size: 0, connections: 3) == [0..<0])
        #expect(TransferPlan.ranges(size: 63 * mb, connections: 3) == [0..<(63 * mb)])
        #expect(TransferPlan.ranges(size: 500 * mb, connections: 1) == [0..<(500 * mb)])
    }

    @Test func largeFilesSplitIntoContiguousChunks() {
        for (size, conns) in [(923_000_000 as UInt64, 3), (20 * 1024 * mb, 3), (64 * mb, 4), (5_000 * mb + 7, 8)] {
            let ranges = TransferPlan.ranges(size: size, connections: conns)
            #expect(ranges.first?.lowerBound == 0)
            #expect(ranges.last?.upperBound == size)
            for (a, b) in zip(ranges, ranges.dropFirst()) { #expect(a.upperBound == b.lowerBound) }
            for r in ranges.dropLast() {
                #expect(r.count >= Int(32 * mb) && r.count <= Int(256 * mb))
                #expect(r.count % Int(mb) == 0)
            }
        }
        // About four chunks per connection for a mid-size file.
        #expect(TransferPlan.ranges(size: 923_000_000, connections: 3).count == 12)
        // 256 MB cap for very large files bounds what an interruption costs.
        #expect(TransferPlan.ranges(size: 20 * 1024 * mb, connections: 3).count == 80)
    }

    @Test func resumePlansOnlyTheGaps() {
        let size = 1024 * mb
        var done = ByteRangeSet()
        done.insert(0..<(300 * mb))
        done.insert((700 * mb)..<(800 * mb))
        let ranges = TransferPlan.ranges(size: size, connections: 3, gaps: done.gaps(in: 0..<size))
        #expect(ranges.first?.lowerBound == 300 * mb)
        #expect(ranges.last?.upperBound == size)
        #expect(ranges.reduce(0) { $0 + UInt64($1.count) } == size - 400 * mb)
        #expect(!ranges.contains { $0.overlaps((700 * mb)..<(800 * mb)) })
    }

    @Test func localNamesEscapeInvalidUTF8() {
        #expect(TransferPlan.localName(RemotePath("Weekly Pack [x] (1).cbz")) == "Weekly Pack [x] (1).cbz")
        #expect(TransferPlan.localName(RemotePath("café")) == "café")
        #expect(TransferPlan.localName(RemotePath(bytes: [0x66, 0xFF, 0x25, 0x6F])) == "f%FF%25o")
    }

    @Test func lastComponent() {
        #expect(RemotePath("files/downloads/Pack/").lastComponent == RemotePath("Pack"))
        #expect(RemotePath("/a/b.mkv").lastComponent == RemotePath("b.mkv"))
        #expect(RemotePath("single").lastComponent == RemotePath("single"))
    }

    @Test func readStrategyFollowsServerLimits() throws {
        var payload = ByteBuffer()
        for v: UInt64 in [262_144, 261_120, 261_120, 0] { payload.writeInteger(v) }
        let openssh = ReadStrategy.for(limits: try SFTPLimits(payload: payload))
        #expect(openssh == ReadStrategy(readSize: 261_120, maxInFlight: 32))
        #expect(ReadStrategy.for(limits: nil) == ReadStrategy(readSize: 65_536, maxInFlight: 128))
    }
}

@Suite struct PartFileTests {
    @Test func writesAtOffsetsAndHashes() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
        defer { unlink(path) }
        let part = try PartFile.create(at: path, size: 6)
        let loop = NIOSingletons.posixEventLoopGroup.next()
        try await part.write(ByteBuffer(bytes: Array("def".utf8)), at: 3, on: loop).get()
        try await part.write(ByteBuffer(bytes: Array("abc".utf8)), at: 0, on: loop).get()
        try part.sync()
        part.close()
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "abcdef")
        // printf abcdef | shasum -a 256
        #expect(try localSHA256(path: path) == "bef57ec7f53a6d40beb640a780a639c83bc29ac8a9816f1fc6c5c6dcd93c4721")
    }
}

@Suite struct ByteRangeSetTests {
    @Test func mergesOverlappingAndAdjacentRanges() {
        var set = ByteRangeSet()
        set.insert(10..<20)
        set.insert(30..<40)
        set.insert(20..<25)        // touches 10..<20
        set.insert(35..<50)        // overlaps 30..<40
        set.insert(0..<0)          // empty: ignored
        #expect(set.ranges == [10..<25, 30..<50])
        #expect(set.byteCount == 35)
        set.insert(0..<100)
        #expect(set.ranges == [0..<100])
    }

    @Test func gapsWithinATotal() {
        let set = ByteRangeSet([10..<20, 30..<40])
        #expect(set.gaps(in: 0..<50) == [0..<10, 20..<30, 40..<50])
        #expect(set.gaps(in: 15..<35) == [20..<30])
        #expect(ByteRangeSet().gaps(in: 0..<5) == [0..<5])
        #expect(ByteRangeSet([0..<5]).gaps(in: 0..<5).isEmpty)
    }

    @Test func roundTripsThroughJSON() throws {
        let set = ByteRangeSet([0..<268_435_456, 536_870_912..<805_306_368])
        let decoded = try JSONDecoder().decode(ByteRangeSet.self, from: JSONEncoder().encode(set))
        #expect(decoded == set)
    }
}

@Suite struct RemoteHasherTests {
    @Test func parsesScriptOutput() {
        let hash = String(repeating: "ab", count: 32)
        let result = RemoteHasher.parse(scriptOutput: Array("\(hash) 923500000 1758700000 cached\n".utf8))
        #expect(result == RemoteHasher.Result(sha256: hash, size: 923_500_000, modificationTime: 1_758_700_000, cached: true))
        #expect(RemoteHasher.parse(scriptOutput: Array("\(hash) 1 2 computed".utf8))?.cached == false)
        #expect(RemoteHasher.parse(scriptOutput: Array("sh: stat: not found\n".utf8)) == nil)
        #expect(RemoteHasher.parse(scriptOutput: []) == nil)
    }

    /// Runs the real script under /bin/sh with a GNU-style `stat -c` shim (macOS
    /// stat uses -f), against awkward filenames: first computed, then cached.
    @Test func scriptHashesAndCachesAwkwardFilenames() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("blit-hash-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("bin")
        try fm.createDirectory(at: bin, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let shim = bin.appendingPathComponent("stat")
        try "#!/bin/sh\n# GNU-style: stat -L -c \"%s %Y %Z %i\" -- FILE\nexec /usr/bin/stat -L -f \"%z %m %c %i\" \"$5\"\n"
            .write(to: shim, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: shim.path)

        for name in ["plain.bin", "it's a \"quoted\" name $(x).bin", "new\nline.bin"] {
            let file = root.appendingPathComponent(name)
            try Data("abcdef".utf8).write(to: file)
            func run(bypassCache: Bool = false) throws -> RemoteHasher.Result? {
                try runScript(file, bin: bin, home: root, bypassCache: bypassCache)
            }
            let first = try #require(try run())
            #expect(first.sha256 == "bef57ec7f53a6d40beb640a780a639c83bc29ac8a9816f1fc6c5c6dcd93c4721")
            #expect(first.size == 6)
            #expect(!first.cached)
            #expect(try run()?.cached == true)
            #expect(try run(bypassCache: true)?.cached == false)
        }

        // A failed read must never produce (or cache) a hash of a truncated
        // stream: an unreadable file exits with no result, and stays uncached.
        let locked = root.appendingPathComponent("locked.bin")
        try Data("secret".utf8).write(to: locked)
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        #expect(try runScript(locked, bin: bin, home: root) == nil)
        #expect(try runScript(locked, bin: bin, home: root) == nil)
    }

    private func runScript(_ file: URL, bin: URL, home: URL, bypassCache: Bool = false) throws -> RemoteHasher.Result? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", RemoteHasher.script, "blit", file.path]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = bin.path + ":/usr/bin:/bin:/usr/sbin:/sbin"
        env["HOME"] = home.path
        env.removeValue(forKey: "XDG_CACHE_HOME")
        if bypassCache { env["BLIT_NOCACHE"] = "1" } else { env.removeValue(forKey: "BLIT_NOCACHE") }
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        return RemoteHasher.parse(scriptOutput: Array(out.fileHandleForReading.readDataToEndOfFile()))
    }
}

@Suite struct HostKeyStoreTests {
    func tempStore() -> HostKeyStore {
        HostKeyStore(path: FileManager.default.temporaryDirectory.appendingPathComponent("blit-keys-\(UUID().uuidString)/host-keys.json").path)
    }

    @Test func pinTrustsAndForgetRemoves() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(atPath: (store.path as NSString).deletingLastPathComponent) }
        let key = try NIOSSHPublicKey(openSSHPublicKey: ed25519Line)
        let empty = KnownHostsVerifier(path: "/nonexistent")
        let verifier = BlitHostKeyVerifier(store: store, knownHosts: empty)

        guard case .rejected(let presented, let known) = verifier.verify(host: "Example.com", port: 2222, key: key) else {
            Issue.record("expected rejection before pinning")
            return
        }
        #expect(known.isEmpty)
        try store.pin(presented, host: "Example.com", port: 2222)
        try store.pin(presented, host: "example.com", port: 2222)   // duplicate: ignored
        #expect(store.entries(host: "example.com", port: 2222).count == 1)
        #expect(verifier.verify(host: "example.com", port: 2222, key: key) == .trusted)
        #expect(verifier.verify(host: "example.com", port: 3232, key: key) != .trusted)

        #expect(try store.forget(host: "example.com", port: 2222) == 1)
        #expect(verifier.verify(host: "example.com", port: 2222, key: key) != .trusted)
    }

    @Test func distinguishesNewKeyTypeFromChangedKey() throws {
        let store = tempStore()
        defer { try? FileManager.default.removeItem(atPath: (store.path as NSString).deletingLastPathComponent) }
        let ecdsa = try NIOSSHPublicKey(openSSHPublicKey: ecdsaLine)
        let ed25519 = try NIOSSHPublicKey(openSSHPublicKey: ed25519Line)
        try store.pin(HostKeyIdentity(ecdsa), host: "h", port: 22)
        let verifier = BlitHostKeyVerifier(store: store, knownHosts: KnownHostsVerifier(path: "/nonexistent"))

        // A new type (the SFTPGo case) may be offered for trust.
        guard case .rejected(let p1, let k1) = verifier.verify(host: "h", port: 22, key: ed25519) else { return }
        #expect(!SSHError.hostKeyRejected(host: "h", port: 22, presented: p1, known: k1).isChangedHostKey)

        // A different key of a type already trusted must be refused.
        let other = HostKeyIdentity(type: "ecdsa-sha2-nistp256", fingerprint: "SHA256:different")
        #expect(SSHError.hostKeyRejected(host: "h", port: 22, presented: other, known: k1).isChangedHostKey)
    }
}

@Suite struct CollisionTests {
    @Test func detectsNormalizationAndCaseCollisions() {
        let nfc = "Pack/Pok\u{E9}mon.cbz"           // é precomposed
        let nfd = "Pack/Poke\u{301}mon.cbz"         // e + combining acute
        let paths = [nfc, "Pack/readme.nfo", nfd, "Pack/README.NFO", "Pack/other.cbz"]
        #expect(TransferPlan.collisions(paths, caseSensitive: false) == [2: nfc, 3: "Pack/readme.nfo"])
        #expect(TransferPlan.collisions(paths, caseSensitive: true) == [2: nfc])
        #expect(TransferPlan.collisions(["a", "b"], caseSensitive: false).isEmpty)
    }
}

@Suite struct RemoteHasherProgressTests {
    @Test func parsesDDProgress() {
        let chunk = Array("\r268435456 bytes (268 MB, 256 MiB) copied, 1 s, 268 MB/s\r536870912 bytes (537 MB, 512 MiB) copied, 2 s, 268 MB/s".utf8)
        #expect(RemoteHasher.progressBytes(chunk) == 536_870_912)
        let summary = Array("640+0 records in\n640+0 records out\n2684354560 bytes (2.7 GB, 2.5 GiB) copied, 9.8 s, 274 MB/s\n".utf8)
        #expect(RemoteHasher.progressBytes(summary) == 2_684_354_560)
        #expect(RemoteHasher.progressBytes(Array("dd: unknown operand".utf8)) == nil)
    }

    @Test func scriptHasNoSingleQuotes() {
        #expect(!RemoteHasher.script.contains("'"))
    }
}

@Suite struct LocalNameSafetyTests {
    @Test func serverNamesCannotLeaveTheFolder() {
        #expect(TransferPlan.localName(RemotePath("x/../../../Library/evil.plist")) == "x%2F..%2F..%2F..%2FLibrary%2Fevil.plist")
        #expect(TransferPlan.localName(RemotePath("..")) == "%2E%2E")
        #expect(TransferPlan.localName(RemotePath(".")) == "%2E")
        #expect(TransferPlan.localName(RemotePath(bytes: [0x61, 0x2F, 0xFF])) == "a%2F%FF")
        #expect(TransferPlan.localName(RemotePath("Movie.2160p.mkv")) == "Movie.2160p.mkv")
        #expect(TransferPlan.isContained("Pack/Sample/a.mkv"))
        #expect(!TransferPlan.isContained("Pack/../../a.mkv"))
        #expect(!TransferPlan.isContained("/etc/passwd"))
        #expect(!TransferPlan.isContained("Pack//a.mkv"))
    }
}

@Suite struct RenameIntoPlaceTests {
    @Test func neverReplacesSomethingThatAppeared() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("blit-rename-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let part = dir.appendingPathComponent("a.mkv.blitpart").path
        let final = dir.appendingPathComponent("a.mkv").path

        try Data("new".utf8).write(to: URL(fileURLWithPath: part))
        try renameIntoPlace(part, final, overwrite: false)
        #expect(try String(contentsOfFile: final, encoding: .utf8) == "new")

        // Someone else created the final name meanwhile: kept, not replaced.
        try Data("newer".utf8).write(to: URL(fileURLWithPath: part))
        #expect(throws: POSIXFailure.self) { try renameIntoPlace(part, final, overwrite: false) }
        #expect(try String(contentsOfFile: final, encoding: .utf8) == "new")
        #expect(fm.fileExists(atPath: part))

        // --overwrite replaces.
        try renameIntoPlace(part, final, overwrite: true)
        #expect(try String(contentsOfFile: final, encoding: .utf8) == "newer")
    }
}

@Suite struct HashedKnownHostsTests {
    @Test func matchesOpenSSHHashedEntries() {
        // `ssh-keygen -H` style entry for "[example.org]:2222", salt "blitsalt".
        let salt = Data("blitsalt".utf8)
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data("[example.org]:2222".utf8), using: SymmetricKey(data: salt))
        let field = "|1|\(salt.base64EncodedString())|\(Data(mac).base64EncodedString())"
        #expect(hashedEntry(field, matches: "[example.org]:2222"))
        #expect(!hashedEntry(field, matches: "example.org"))
        #expect(!hashedEntry("|1|notbase64|x", matches: "example.org"))
    }
}

/// Key files as ssh-keygen writes them (PRD R1.1).
struct SSHKeyFileTests {
    private func keygen(_ args: [String]) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("key").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = args + ["-q", "-C", "test", "-f", path]
        try p.run()
        p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        return path
    }

    @Test(arguments: [["-t", "ed25519"], ["-t", "ecdsa", "-b", "256"], ["-t", "ecdsa", "-b", "384"],
                      ["-t", "ecdsa", "-b", "521"], ["-t", "ecdsa", "-b", "256", "-m", "PEM"],
                      ["-t", "ecdsa", "-b", "384", "-m", "PEM"], ["-t", "ecdsa", "-b", "521", "-m", "PEM"]])
    func supportedKeysMatchTheirPublicKeys(_ args: [String]) throws {
        let path = try keygen(args + ["-N", ""])
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let key = try SSHKeyFile.load(path)
        let pub = try String(contentsOfFile: path + ".pub", encoding: .utf8)
            .split(separator: " ").prefix(2).joined(separator: " ")
        #expect(key.publicKey == (try NIOSSHPublicKey(openSSHPublicKey: pub)))
    }

    @Test func refusesPassphraseAndRSA() throws {
        let encrypted = try keygen(["-t", "ed25519", "-N", "secret"])
        #expect { try SSHKeyFile.load(encrypted) } throws: { error in
            if case SSHKeyError.encrypted = error { true } else { false }
        }
        let rsa = try keygen(["-t", "rsa", "-b", "2048", "-N", ""])
        #expect { try SSHKeyFile.load(rsa) } throws: { error in
            if case SSHKeyError.unsupportedType("RSA") = error { true } else { false }
        }
        #expect(throws: SSHKeyError.self) { try SSHKeyFile.load("/nonexistent/key") }
        for path in [encrypted, rsa] { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
    }
}

/// Signs in to an in-process SSH server with a key file (PRD R1.1).
struct KeyLoginTests {
    private struct TrustAll: HostKeyVerifier {
        func verify(host: String, port: Int, key: NIOSSHPublicKey) -> HostKeyVerdict { .trusted }
    }

    /// Accepts only public-key sign-in with `allowed`.
    private final class KeyOnlyServer: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
        let allowed: NIOSSHPublicKey
        init(allowed: NIOSSHPublicKey) { self.allowed = allowed }
        var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods { .publicKey }
        func requestReceived(request: NIOSSHUserAuthenticationRequest,
                             responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
            if case .publicKey(let key) = request.request, key.publicKey == allowed {
                responsePromise.succeed(.success)
            } else {
                responsePromise.succeed(.failure)
            }
        }
    }

    private func server(allowing key: NIOSSHPublicKey) async throws -> Channel {
        let hostKey = NIOSSHPrivateKey(ed25519Key: .init())
        let delegate = KeyOnlyServer(allowed: key)
        return try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(NIOSSHHandler(
                        role: .server(.init(hostKeys: [hostKey], userAuthDelegate: delegate)),
                        allocator: channel.allocator, inboundChildChannelInitializer: nil))
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    private func keyFile(_ type: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("key").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-q", "-t", type, "-N", "", "-C", "test", "-f", path]
        try p.run()
        p.waitUntilExit()
        return path
    }

    @Test(arguments: ["ed25519", "ecdsa"])
    func signsInWithTheKey(_ type: String) async throws {
        let path = try keyFile(type)
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let key = try SSHKeyFile.load(path)
        let listener = try await server(allowing: key.publicKey)
        let endpoint = SSHEndpoint(host: "127.0.0.1", port: listener.localAddress!.port!, username: "test")
        let connection = try await SSHConnection.connect(to: endpoint, credential: .privateKey(key), verifier: TrustAll())
        #expect(connection.isActive)
        await connection.close()

        // A different key is refused.
        let other = NIOSSHPrivateKey(ed25519Key: .init())
        await #expect {
            _ = try await SSHConnection.connect(to: endpoint, credential: .privateKey(other), verifier: TrustAll())
        } throws: { error in
            if case SSHError.authenticationFailed = error { true } else { false }
        }
        try await listener.close()
    }
}
