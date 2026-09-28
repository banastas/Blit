// Regression tests for the protocol-layer QA fixes: known_hosts seeding
// (PRD R1.3) must also match `ssh-keygen -H` hashed (HMAC-SHA1 `|1|`) entries.

import CryptoKit
import Foundation
import NIOSSH
import Testing

@testable import BlitRemote

/// An `ssh-keygen -H` style first field for `pattern`:
/// `|1|base64(salt)|base64(HMAC-SHA1(salt, pattern))`.
private func hashedField(for pattern: String, salt: Data) -> String {
    let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(pattern.utf8), using: SymmetricKey(data: salt))
    return "|1|\(salt.base64EncodedString())|\(Data(mac).base64EncodedString())"
}

@Suite struct HashedKnownHostsRegressionTests {
    // ssh-keygen uses a random 20-byte salt per line; any salt works here.
    let salt = Data((0..<20).map { UInt8($0 * 7 &+ 3) })

    @Test func seedsHashedEntriesForDefaultAndCustomPorts() throws {
        let text = """
        \(hashedField(for: "seedbox.example", salt: salt)) \(ed25519Line)
        \(hashedField(for: "[seedbox.example]:2222", salt: salt)) \(ecdsaLine)
        """
        #expect(KnownHostsVerifier.keys(in: text, host: "seedbox.example", port: 22)
            .map { HostKeyIdentity($0).type } == ["ssh-ed25519"])
        #expect(KnownHostsVerifier.keys(in: text, host: "seedbox.example", port: 2222)
            .map { HostKeyIdentity($0).type } == ["ecdsa-sha2-nistp256"])
        // The MAC covers host and port: nothing matches other names or ports.
        #expect(KnownHostsVerifier.keys(in: text, host: "seedbox.example", port: 2200).isEmpty)
        #expect(KnownHostsVerifier.keys(in: text, host: "other.example", port: 22).isEmpty)
    }

    @Test func hashedEntryTrustsWithoutAPrompt() throws {
        // R1.3: a key ssh already trusts (HashKnownHosts) seeds Blit's trust,
        // so first connect doesn't show the fingerprint prompt.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("known_hosts").path
        try "\(hashedField(for: "[seedbox.example]:2222", salt: salt)) \(ed25519Line)\n"
            .write(toFile: path, atomically: true, encoding: .utf8)

        let key = try NIOSSHPublicKey(openSSHPublicKey: ed25519Line)
        #expect(KnownHostsVerifier(path: path).verify(host: "seedbox.example", port: 2222, key: key) == .trusted)
        // Same host on the default port is a different pattern: still a prompt.
        #expect(KnownHostsVerifier(path: path).verify(host: "seedbox.example", port: 22, key: key)
            == .rejected(presented: HostKeyIdentity(key), known: []))
    }

    @Test func malformedHashedEntriesNeverMatch() {
        // Unknown hash version, truncated fields, bad base64: skipped, never trusted.
        #expect(!hashedEntry("|2|\(salt.base64EncodedString())|AAAA", matches: "seedbox.example"))
        #expect(!hashedEntry("|1|\(salt.base64EncodedString())", matches: "seedbox.example"))
        #expect(!hashedEntry("|1|not*base64|salt!!", matches: "seedbox.example"))
        // A well-formed entry whose MAC is for another host.
        #expect(!hashedEntry(hashedField(for: "other.example", salt: salt), matches: "seedbox.example"))
    }
}
