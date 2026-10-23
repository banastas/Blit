// Host key verification (PRD R1.3). SwiftNIO SSH negotiates the server's
// preferred key type, which may not be the type recorded in known_hosts, so a
// rejection reports both what was presented and what is on file.

import CryptoKit
import Foundation
import NIOSSH

public struct HostKeyIdentity: Hashable, Sendable, CustomStringConvertible {
    /// OpenSSH key type, e.g. "ssh-ed25519".
    public let type: String
    /// OpenSSH fingerprint, e.g. "SHA256:DolUu193…".
    public let fingerprint: String

    public init(_ key: NIOSSHPublicKey) {
        let parts = String(openSSHPublicKey: key).split(separator: " ")
        type = parts.first.map(String.init) ?? "unknown"
        if parts.count > 1, let blob = Data(base64Encoded: String(parts[1])) {
            let digest = Data(SHA256.hash(data: blob)).base64EncodedString()
            fingerprint = "SHA256:" + digest.replacingOccurrences(of: "=", with: "")
        } else {
            fingerprint = "SHA256:?"
        }
    }

    public var description: String { "\(type) \(fingerprint)" }
}

public enum HostKeyVerdict: Sendable, Equatable {
    case trusted
    case rejected(presented: HostKeyIdentity, known: [HostKeyIdentity])
    /// Listed with @revoked in known_hosts: refused outright, never offered for trust.
    case revoked(presented: HostKeyIdentity)
}

public protocol HostKeyVerifier: Sendable {
    func verify(host: String, port: Int, key: NIOSSHPublicKey) -> HostKeyVerdict
}

/// Trusts keys listed in an OpenSSH known_hosts file (plain, unhashed entries),
/// plus any explicitly pinned fingerprints.
/// OpenSSH's hashed host entry: `|1|base64(salt)|base64(HMAC-SHA1(salt, host))`.
func hashedEntry(_ field: String, matches pattern: String) -> Bool {
    let parts = field.split(separator: "|", omittingEmptySubsequences: true)
    guard parts.count == 3, parts[0] == "1",
          let salt = Data(base64Encoded: String(parts[1])), let expected = Data(base64Encoded: String(parts[2])) else { return false }
    let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(pattern.utf8), using: SymmetricKey(data: salt))
    return Data(mac) == expected
}

public struct KnownHostsVerifier: HostKeyVerifier {
    public let path: String
    public let pinnedFingerprints: Set<String>

    public init(path: String = NSHomeDirectory() + "/.ssh/known_hosts", pinnedFingerprints: Set<String> = []) {
        self.path = path
        self.pinnedFingerprints = pinnedFingerprints
    }

    public func verify(host: String, port: Int, key: NIOSSHPublicKey) -> HostKeyVerdict {
        let presented = HostKeyIdentity(key)
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        // Revocation comes before every way of trusting a key, as in OpenSSH.
        if Self.revokedKeys(in: text, host: host, port: port).contains(key) { return .revoked(presented: presented) }
        if pinnedFingerprints.contains(presented.fingerprint) { return .trusted }
        let known = Self.keys(in: text, host: host, port: port)
        if known.contains(key) { return .trusted }
        return .rejected(presented: presented, known: known.map(HostKeyIdentity.init))
    }

    /// Whether known_hosts revokes `key` for `host:port` (or for every host, `*`).
    public func isRevoked(host: String, port: Int, key: NIOSSHPublicKey) -> Bool {
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        return Self.revokedKeys(in: text, host: host, port: port).contains(key)
    }

    /// Keys marked `@revoked` for `host:port`: exact, comma-listed, hashed, or `*` (any host).
    static func revokedKeys(in text: String, host: String, port: Int) -> [NIOSSHPublicKey] {
        let pattern = port == 22 ? host : "[\(host)]:\(port)"
        var result: [NIOSSHPublicKey] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 4, fields[0] == "@revoked" else { continue }
            let matches = fields[1] == "*" || (fields[1].hasPrefix("|")
                ? hashedEntry(String(fields[1]), matches: pattern)
                : fields[1].split(separator: ",").contains(where: { $0 == pattern }))
            guard matches else { continue }
            if let key = try? NIOSSHPublicKey(openSSHPublicKey: "\(fields[2]) \(fields[3])") { result.append(key) }
        }
        return result
    }

    /// Keys recorded for `host:port`, including hashed (`|1|salt|hash`,
    /// HashKnownHosts) entries. Marker lines (@revoked, @cert-authority) are
    /// skipped here; revocations are read by `revokedKeys`.
    static func keys(in text: String, host: String, port: Int) -> [NIOSSHPublicKey] {
        let pattern = port == 22 ? host : "[\(host)]:\(port)"
        var result: [NIOSSHPublicKey] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, !fields[0].hasPrefix("#"), !fields[0].hasPrefix("@") else { continue }
            let matches = fields[0].hasPrefix("|")
                ? hashedEntry(String(fields[0]), matches: pattern)
                : fields[0].split(separator: ",").contains(where: { $0 == pattern })
            guard matches else { continue }
            if let key = try? NIOSSHPublicKey(openSSHPublicKey: "\(fields[1]) \(fields[2])") { result.append(key) }
        }
        return result
    }
}
