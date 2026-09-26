// Configured servers (saved in preferences) and their passwords (in the
// macOS Keychain, never on disk in plain text).

import BlitRemote
import Foundation
import Observation
import Security

struct ServerConfig: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name = ""
    var host = ""
    var port = 22
    var username = ""
    /// Folder to open first; empty means the login's home folder.
    var startPath = ""
    /// Connections used for transfers (PRD R3.2); browsing uses one.
    var connections = 3
    /// Set for a NAS login used only to verify copies on the NAS (PRD R1.6):
    /// the share's mount point on this Mac and its path on the NAS.
    /// (Optional so servers saved before this still decode.)
    var nasMountPoint: String?
    var nasRoot: String?
    /// Private key file to sign in with instead of a password (PRD R1.1).
    var keyPath: String?

    var isNASLogin: Bool { nasMountPoint != nil }
    var usesKey: Bool { !(keyPath ?? "").isEmpty }

    var endpoint: SSHEndpoint { SSHEndpoint(host: host, port: port, username: username) }
    var displayName: String { name.isEmpty ? host : name }
    var startLocation: BrowseLocation { .remote(server: id, path: Array(startPath.utf8)) }
}

@MainActor
@Observable
final class ServerStore {
    private(set) var servers: [ServerConfig] = []
    private static let key = "servers"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([ServerConfig].self, from: data) {
            servers = saved
        }
    }

    func server(_ id: UUID?) -> ServerConfig? {
        guard let id else { return nil }
        return servers.first { $0.id == id }
    }

    /// Servers to browse (NAS logins are listed with their share instead).
    var browsable: [ServerConfig] { servers.filter { !$0.isNASLogin } }

    /// The login that verifies copies on the share mounted at `mountPoint`.
    func nasLogin(forMount mountPoint: String) -> ServerConfig? {
        servers.first { $0.nasMountPoint == mountPoint && $0.nasRoot != nil }
    }

    /// Adds or updates a server. A nil or empty password keeps the saved one.
    func save(_ server: ServerConfig, password: String?) {
        if let old = self.server(server.id), old.host != server.host || old.port != server.port || old.username != server.username {
            // The Keychain item is keyed by host, port and user; move it.
            let existing = Keychain.password(for: old)
            Keychain.deletePassword(for: old)
            if let existing, password?.isEmpty != false { Keychain.setPassword(existing, for: server) }
        }
        if let password, !password.isEmpty { Keychain.setPassword(password, for: server) }
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        persist()
    }

    func remove(_ server: ServerConfig) {
        Keychain.deletePassword(for: server)
        servers.removeAll { $0.id == server.id }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(servers) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

/// Internet passwords in the login keychain, keyed by host, port, user and
/// the server entry's id (so two entries for the same account don't share,
/// or delete, one password). Items saved before that (no id) are still read.
extension ServerConfig {
    /// How to sign in: the key file when one is set, else the Keychain password.
    func credential() throws -> SSHCredential {
        if let keyPath, usesKey { return .privateKey(try SSHKeyFile.load(keyPath)) }
        guard let password = Keychain.password(for: self) else { throw ConnectionError.noPassword }
        return .password(password)
    }

    /// Whether Blit can sign in without asking (a key or a saved password).
    var hasCredential: Bool { usesKey || Keychain.password(for: self) != nil }
}

enum Keychain {
    private static func query(_ server: ServerConfig, perEntry: Bool = true) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassInternetPassword,
            kSecAttrServer as String: server.host,
            kSecAttrPort as String: server.port,
            kSecAttrAccount as String: server.username,
            kSecAttrProtocol as String: kSecAttrProtocolSSH,
        ]
        if perEntry { q[kSecAttrPath as String] = "/blit/\(server.id.uuidString)" }
        return q
    }

    static func password(for server: ServerConfig) -> String? {
        func read(_ q: [String: Any]) -> String? {
            var q = q
            q[kSecReturnData as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        if let own = read(query(server)) { return own }
        // Saved before passwords were per entry: use it, and give this entry its own copy.
        guard let legacy = read(query(server, perEntry: false)) else { return nil }
        setPassword(legacy, for: server)
        return legacy
    }

    static func setPassword(_ password: String, for server: ServerConfig) {
        let data = Data(password.utf8)
        let q = query(server)
        let status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q
            add[kSecValueData as String] = data
            add[kSecAttrLabel as String] = "Blit: \(server.displayName)"
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func deletePassword(for server: ServerConfig) {
        SecItemDelete(query(server) as CFDictionary)
    }
}
