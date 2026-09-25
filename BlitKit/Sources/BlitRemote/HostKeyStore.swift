// Blit's own record of trusted host keys (PRD R1.3), alongside known_hosts.

import Foundation
import NIOSSH

public struct HostKeyStore: Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var type: String
        public var fingerprint: String
        public var added: Date
    }

    public let path: String

    public static var defaultPath: String {
        NSHomeDirectory() + "/Library/Application Support/Blit/host-keys.json"
    }

    public init(path: String = HostKeyStore.defaultPath) { self.path = path }

    static func key(host: String, port: Int) -> String { "\(host.lowercased()):\(port)" }

    public func all() -> [String: [Entry]] {
        guard let data = FileManager.default.contents(atPath: path) else { return [:] }
        return (try? JSONDecoder.store.decode([String: [Entry]].self, from: data)) ?? [:]
    }

    public func entries(host: String, port: Int) -> [Entry] { all()[Self.key(host: host, port: port)] ?? [] }

    /// Remembers `identity` for host:port (in addition to any other key types on file).
    public func pin(_ identity: HostKeyIdentity, host: String, port: Int) throws {
        var store = all()
        var list = store[Self.key(host: host, port: port)] ?? []
        guard !list.contains(where: { $0.fingerprint == identity.fingerprint }) else { return }
        list.append(Entry(type: identity.type, fingerprint: identity.fingerprint, added: Date()))
        store[Self.key(host: host, port: port)] = list
        try save(store)
    }

    /// Forgets every key for host:port; returns how many were removed.
    @discardableResult
    public func forget(host: String, port: Int) throws -> Int {
        var store = all()
        let removed = store.removeValue(forKey: Self.key(host: host, port: port))?.count ?? 0
        if removed > 0 { try save(store) }
        return removed
    }

    private func save(_ store: [String: [Entry]]) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.store.encode(store).write(to: url, options: [.atomic])
    }
}

extension JSONEncoder {
    static var store: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
}

extension JSONDecoder {
    static var store: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Trusts keys in Blit's store, in known_hosts, or pinned for this session.
public struct BlitHostKeyVerifier: HostKeyVerifier {
    public let store: HostKeyStore
    public let knownHosts: KnownHostsVerifier

    public init(store: HostKeyStore = HostKeyStore(), knownHosts: KnownHostsVerifier = KnownHostsVerifier()) {
        self.store = store
        self.knownHosts = knownHosts
    }

    public func verify(host: String, port: Int, key: NIOSSHPublicKey) -> HostKeyVerdict {
        let presented = HostKeyIdentity(key)
        let stored = store.entries(host: host, port: port)
        if stored.contains(where: { $0.fingerprint == presented.fingerprint }) { return .trusted }
        switch knownHosts.verify(host: host, port: port, key: key) {
        case .trusted:
            return .trusted
        case .rejected(_, let known):
            let fromStore = stored.map { HostKeyIdentity(type: $0.type, fingerprint: $0.fingerprint) }
            return .rejected(presented: presented, known: fromStore + known.filter { k in !fromStore.contains(k) })
        }
    }
}

extension HostKeyIdentity {
    public init(type: String, fingerprint: String) {
        self.type = type
        self.fingerprint = fingerprint
    }
}

extension SSHError {
    /// A key of the presented type is already trusted for this server, but it's
    /// a different key: possible interception. Never offer to replace it.
    public var isChangedHostKey: Bool {
        if case .hostKeyRejected(_, _, let presented, let known) = self {
            return known.contains { $0.type == presented.type }
        }
        return false
    }
}
