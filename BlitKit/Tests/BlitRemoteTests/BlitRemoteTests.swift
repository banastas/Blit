import Foundation
import NIOCore
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
                #expect(r.count >= Int(32 * mb) && r.count <= Int(1024 * mb))
                #expect(r.count % Int(mb) == 0)
            }
        }
        // About four chunks per connection for a mid-size file.
        #expect(TransferPlan.ranges(size: 923_000_000, connections: 3).count == 12)
        // 1 GB cap for very large files.
        #expect(TransferPlan.ranges(size: 20 * 1024 * mb, connections: 3).count == 20)
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
