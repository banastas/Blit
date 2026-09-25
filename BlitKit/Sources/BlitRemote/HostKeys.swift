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
}

public protocol HostKeyVerifier: Sendable {
    func verify(host: String, port: Int, key: NIOSSHPublicKey) -> HostKeyVerdict
}

/// Trusts keys listed in an OpenSSH known_hosts file (plain, unhashed entries),
/// plus any explicitly pinned fingerprints.
public struct KnownHostsVerifier: HostKeyVerifier {
    public let path: String
    public let pinnedFingerprints: Set<String>

    public init(path: String = NSHomeDirectory() + "/.ssh/known_hosts", pinnedFingerprints: Set<String> = []) {
        self.path = path
        self.pinnedFingerprints = pinnedFingerprints
    }

    public func verify(host: String, port: Int, key: NIOSSHPublicKey) -> HostKeyVerdict {
        let presented = HostKeyIdentity(key)
        if pinnedFingerprints.contains(presented.fingerprint) { return .trusted }
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        let known = Self.keys(in: text, host: host, port: port)
        if known.contains(key) { return .trusted }
        return .rejected(presented: presented, known: known.map(HostKeyIdentity.init))
    }

    /// Keys recorded for `host:port`. Hashed (`|1|…`) entries and markers are skipped.
    static func keys(in text: String, host: String, port: Int) -> [NIOSSHPublicKey] {
        let pattern = port == 22 ? host : "[\(host)]:\(port)"
        var result: [NIOSSHPublicKey] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 3, !fields[0].hasPrefix("#"), !fields[0].hasPrefix("|"), !fields[0].hasPrefix("@") else { continue }
            guard fields[0].split(separator: ",").contains(where: { $0 == pattern }) else { continue }
            if let key = try? NIOSSHPublicKey(openSSHPublicKey: "\(fields[1]) \(fields[2])") { result.append(key) }
        }
        return result
    }
}
