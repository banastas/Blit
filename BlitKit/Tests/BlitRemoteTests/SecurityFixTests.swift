// Regression tests for the security audit's Blit leads: @revoked host keys are
// refused before any trust source, and server- or file-supplied sizes and
// ranges can't trap (a Swift overflow ends the whole app).

import Foundation
import NIOCore
import NIOSSH
import Testing

@testable import BlitRemote
@testable import BlitSFTP

private func temporary(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("blit-\(name)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite struct RevokedHostKeyTests {
    func knownHosts(_ text: String) throws -> KnownHostsVerifier {
        let path = try temporary("known").appendingPathComponent("known_hosts").path
        try text.write(toFile: path, atomically: true, encoding: .utf8)
        return KnownHostsVerifier(path: path)
    }

    @Test func revokedBeatsAPlainLine() throws {
        let key = try NIOSSHPublicKey(openSSHPublicKey: ed25519Line)
        let verifier = try knownHosts("@revoked example.com \(ed25519Line)\nexample.com \(ed25519Line)\n")
        #expect(verifier.verify(host: "example.com", port: 22, key: key) == .revoked(presented: HostKeyIdentity(key)))
    }

    @Test func revokedBeatsBlitsOwnPin() throws {
        let key = try NIOSSHPublicKey(openSSHPublicKey: ed25519Line)
        let store = HostKeyStore(path: try temporary("store").appendingPathComponent("host-keys.json").path)
        try store.pin(HostKeyIdentity(key), host: "example.com", port: 22)
        let verifier = BlitHostKeyVerifier(store: store, knownHosts: try knownHosts("@revoked example.com \(ed25519Line)\n"))
        #expect(verifier.verify(host: "example.com", port: 22, key: key) == .revoked(presented: HostKeyIdentity(key)))
        // Another host isn't affected by that revocation.
        try store.pin(HostKeyIdentity(key), host: "other.example", port: 22)
        #expect(verifier.verify(host: "other.example", port: 22, key: key) == .trusted)
    }

    @Test func revokedForEveryHost() throws {
        let key = try NIOSSHPublicKey(openSSHPublicKey: ed25519Line)
        let verifier = try knownHosts("@revoked * \(ed25519Line)\n")
        #expect(verifier.verify(host: "anything.example", port: 2222, key: key) == .revoked(presented: HostKeyIdentity(key)))
        #expect(verifier.verify(host: "anything.example", port: 2222,
                                key: try NIOSSHPublicKey(openSSHPublicKey: ecdsaLine)) != .revoked(presented: HostKeyIdentity(key)))
    }
}

@Suite struct UntrustedSizeTests {
    @Test func hugeSFTPSizeIsClamped() throws {
        var buffer = ByteBuffer()
        buffer.writeInteger(UInt32(0x0000_0001))   // SSH_FILEXFER_ATTR_SIZE
        buffer.writeInteger(UInt64.max)
        let attributes = try SFTPAttributes.read(from: &buffer)
        #expect(attributes.size == UInt64(Int64.max))
        #expect(Int64(clamping: attributes.size ?? 0) == .max)
    }

    @Test func sumsSaturate() {
        #expect([UInt64.max, 5].saturatingSum { $0 } == .max)
        #expect([UInt64(2), 3].saturatingSum { $0 } == 5)
    }

    @Test func decodedRangesAreMergedSoTheyCantOverflow() throws {
        let json = #"{"ranges":[[0,10000000000000000000],[0,10000000000000000000],[5,20]]}"#
        let set = try JSONDecoder().decode(ByteRangeSet.self, from: Data(json.utf8))
        #expect(set.ranges == [0..<10_000_000_000_000_000_000])
        #expect(set.byteCount == 10_000_000_000_000_000_000)
        #expect(set.gaps(in: 0..<10_000_000_000_000_000_000).isEmpty)
    }

    @Test func craftedSidecarDoesntCrashTheBrowser() throws {
        let folder = try temporary("sidecar")
        let part = folder.appendingPathComponent("a.blitpart").path
        FileManager.default.createFile(atPath: part, contents: Data())
        let state = #"{"version":1,"remotePath":"","size":1,"done":{"ranges":[[0,10000000000000000000],[0,10000000000000000000]]}}"#
        try Data(state.utf8).write(to: URL(fileURLWithPath: part + ".state"))
        let partial = try #require(PartialDownload.read(partPath: part))
        #expect(partial.done == 1)   // capped at the stated size
    }

    @Test func partFileRefusesAnImpossibleSize() throws {
        let part = try temporary("bigpart").appendingPathComponent("x.blitpart").path
        #expect(throws: POSIXFailure.self) { try PartFile.create(at: part, size: UInt64.max) }
    }

    @Test func rangesForTheLargestAllowedSizeDontOverflow() {
        let size = UInt64(Int64.max)
        let ranges = TransferPlan.ranges(size: size, connections: 1)
        #expect(ranges == [0..<size])
    }
}
