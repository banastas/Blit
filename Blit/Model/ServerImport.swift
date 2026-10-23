// Import Servers (PRD R1.8): the SFTP favorites saved in Transmit and
// ForkLift, so switching to Blit doesn't start with typing them all in again.
// Read only, never written: Transmit's connection store (a keyed archive,
// decoded with stand-ins for its classes; its Spotlight metadata files if the
// store can't be read), and ForkLift's favorites file (JSON or a property
// list, read leniently). Passwords aren't read: they stay in those apps'
// Keychain items, and Blit asks for one on the first connection.

import Foundation

struct ImportedServer: Identifiable, Hashable {
    let id = UUID()
    /// "Transmit" or "ForkLift".
    var source: String
    var name: String
    var host: String
    var port: Int
    var username: String
    var path: String
    var keyPath: String?

    var config: ServerConfig {
        var server = ServerConfig()
        server.name = name
        server.host = host
        server.port = port
        server.username = username
        server.startPath = path
        server.keyPath = keyPath
        return server
    }

    /// Already in Blit: the same host, port and user.
    func matches(_ server: ServerConfig) -> Bool {
        server.host.caseInsensitiveCompare(host) == .orderedSame && server.port == port && server.username == username
    }
}

enum ServerImport {
    /// The home folder searched (a test copy can point it at stand-ins).
    static var home: URL {
        #if DEBUG
        if let path = UserDefaults.standard.string(forKey: "BlitImportHome") { return URL(fileURLWithPath: path) }
        #endif
        return URL(fileURLWithPath: NSHomeDirectory())
    }

    /// Everything found under `home`, duplicates (the same login in both apps) once.
    static func find(home: URL = ServerImport.home) -> [ImportedServer] {
        var found: [ImportedServer] = []
        for server in transmit(home: home) + forkLift(home: home)
            where !found.contains(where: { $0.host.caseInsensitiveCompare(server.host) == .orderedSame && $0.port == server.port && $0.username == server.username }) {
            found.append(server)
        }
        return found
    }

    // MARK: Transmit

    /// The direct download's folder, then the App Store version's.
    static func transmitFolders(home: URL) -> [URL] {
        ["Library/Application Support/Transmit",
         "Library/Containers/com.panic.transmit.mas/Data/Library/Application Support/Transmit"].map { home.appendingPathComponent($0) }
    }

    static func transmit(home: URL) -> [ImportedServer] {
        for folder in transmitFolders(home: home) {
            if let data = try? Data(contentsOf: folder.appendingPathComponent("Connections.transmitstore")) {
                let servers = transmitStore(data)
                if !servers.isEmpty { return servers }
            }
            let metadata = folder.appendingPathComponent("Metadata")
            let files = (try? FileManager.default.contentsOfDirectory(at: metadata, includingPropertiesForKeys: nil)) ?? []
            let servers = files.filter { $0.pathExtension == "favoriteMetadata" }.sorted { $0.path < $1.path }
                .compactMap { (try? Data(contentsOf: $0)).flatMap(transmitMetadata) }
            if !servers.isEmpty { return servers }
        }
        return []
    }

    /// 'SFTP', as Transmit stores a connection's protocol.
    static let transmitSFTP = 0x5346_5450

    /// Classes a Transmit store may decode into: the stand-ins and plain
    /// Foundation values. Secure coding refuses anything else, so a store
    /// another app wrote can't make Blit create arbitrary objects (and run
    /// their init(coder:)) inside a process with Full Disk Access.
    static let transmitClasses: [AnyClass] = [TransmitGroup.self, TransmitConnection.self, ArchivedIgnored.self,
                                              NSArray.self, NSDictionary.self, NSSet.self, NSString.self, NSNumber.self,
                                              NSData.self, NSDate.self, NSURL.self, NSUUID.self, NSNull.self]

    /// Transmit's Connections.transmitstore: the favorites in every group.
    static func transmitStore(_ data: Data) -> [ImportedServer] {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return [] }
        unarchiver.requiresSecureCoding = true
        unarchiver.decodingFailurePolicy = .setErrorAndReturn
        let standIns = StandIns()
        unarchiver.delegate = standIns
        unarchiver.setClass(TransmitConnection.self, forClassName: "TRConnectionItem")
        unarchiver.setClass(TransmitGroup.self, forClassName: "TRConnectionGroup")
        let root = unarchiver.decodeObject(of: transmitClasses, forKey: NSKeyedArchiveRootObjectKey)
        unarchiver.finishDecoding()
        var servers: [ImportedServer] = []
        func walk(_ object: Any?) {
            switch object {
            case let group as TransmitGroup: group.children.forEach(walk)
            case let connection as TransmitConnection:
                guard connection.protocolCode == transmitSFTP, !connection.address.isEmpty else { return }
                servers.append(ImportedServer(source: "Transmit", name: connection.name, host: connection.address,
                                              port: connection.port > 0 ? connection.port : 22, username: connection.username,
                                              path: connection.remotePath, keyPath: connection.privateKey))
            case let dictionary as NSDictionary: walk(dictionary["globalConnectionGroup"])
            case let array as NSArray: array.forEach(walk)
            default: break
            }
        }
        walk(root)
        return servers
    }

    /// One of Transmit's Spotlight files for a favorite (Metadata/*.favoriteMetadata).
    static func transmitMetadata(_ data: Data) -> ImportedServer? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              (plist["com_panic_transmit_protocol"] as? String)?.uppercased() == "SFTP",
              let host = plist["com_panic_transmit_server"] as? String, !host.isEmpty else { return nil }
        return ImportedServer(source: "Transmit", name: plist["com_panic_transmit_nickname"] as? String ?? host, host: host,
                              port: (plist["com_panic_transmit_port"] as? Int).flatMap { $0 > 0 ? $0 : nil } ?? 22,
                              username: plist["com_panic_transmit_username"] as? String ?? "",
                              path: plist["com_panic_transmit_remotePath"] as? String ?? "")
    }

    // MARK: ForkLift

    /// ForkLift 3 and 4, direct and App Store: any favorites file in their folders.
    static func forkLiftFiles(home: URL) -> [URL] {
        let fm = FileManager.default
        var bases = [home.appendingPathComponent("Library/Application Support")]
        let containers = home.appendingPathComponent("Library/Containers")
        for name in (try? fm.contentsOfDirectory(atPath: containers.path)) ?? [] where name.lowercased().contains("forklift") {
            bases.append(containers.appendingPathComponent(name).appendingPathComponent("Data/Library/Application Support"))
        }
        var files: [URL] = []
        for base in bases {
            for name in (try? fm.contentsOfDirectory(atPath: base.path)) ?? [] where name.lowercased().hasPrefix("forklift") {
                let folder = base.appendingPathComponent(name)
                guard let walker = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { continue }
                while let url = walker.nextObject() as? URL {
                    if walker.level > 3 { walker.skipDescendants() }
                    let lower = url.lastPathComponent.lowercased()
                    if lower.contains("favorite"), ["json", "plist"].contains(url.pathExtension.lowercased()) { files.append(url) }
                }
            }
        }
        return files
    }

    static func forkLift(home: URL) -> [ImportedServer] {
        forkLiftFiles(home: home).flatMap { url in (try? Data(contentsOf: url)).map(forkLiftFavorites) ?? [] }
    }

    /// A ForkLift favorites file, JSON or a property list: every entry, at any
    /// depth (groups nest them), that names an SFTP server.
    static func forkLiftFavorites(_ data: Data) -> [ImportedServer] {
        let object = (try? JSONSerialization.jsonObject(with: data)) ?? (try? PropertyListSerialization.propertyList(from: data, format: nil))
        var servers: [ImportedServer] = []
        func text(_ entry: [String: Any], _ keys: [String]) -> String? {
            for key in keys {
                if let value = entry.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value as? String, !value.isEmpty { return value }
            }
            return nil
        }
        func number(_ entry: [String: Any], _ keys: [String]) -> Int? {
            for key in keys {
                switch entry.first(where: { $0.key.caseInsensitiveCompare(key) == .orderedSame })?.value {
                case let value as Int: return value
                case let value as String: if let number = Int(value) { return number }
                default: continue
                }
            }
            return nil
        }
        func walk(_ object: Any?) {
            if let array = object as? [Any] { return array.forEach(walk) }
            guard let entry = object as? [String: Any] else { return }
            entry.values.forEach { if $0 is [Any] || $0 is [String: Any] { walk($0) } }
            guard let host = text(entry, ["server", "host", "hostname", "address"]) else { return }
            let scheme = text(entry, ["protocol", "type", "scheme", "connectionType"])?.lowercased()
            let port = number(entry, ["port"])
            // SFTP said outright, or no protocol given on the SSH port.
            guard scheme.map({ $0.contains("sftp") || $0 == "ssh" }) ?? (port == 22) else { return }
            servers.append(ImportedServer(source: "ForkLift", name: text(entry, ["title", "name", "nickname"]) ?? host, host: host,
                                          port: port.flatMap { $0 > 0 ? $0 : nil } ?? 22,
                                          username: text(entry, ["username", "user", "login", "account"]) ?? "",
                                          path: text(entry, ["path", "remotePath", "remote_path", "initialPath", "directory"]) ?? "",
                                          keyPath: text(entry, ["privateKey", "keyPath", "privateKeyPath", "identityFile"])))
        }
        walk(object)
        return servers
    }
}

// MARK: Stand-ins for Transmit's archived classes

/// TRConnectionItem: the fields an import uses (the rest, and its parent, aren't read).
final class TransmitConnection: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let name: String, address: String, username: String, remotePath: String
    let port: Int, protocolCode: Int
    let privateKey: String?

    init?(coder: NSCoder) {
        // Typed decodes only (secure coding): a field of any other class reads as missing.
        func text(_ key: String) -> String { coder.decodeObject(of: NSString.self, forKey: key) as String? ?? "" }
        // An NSNumber object, or a number written inline (decodeObject doesn't return those).
        func integer(_ key: String) -> Int {
            if let number = coder.decodeObject(of: NSNumber.self, forKey: key) { return number.intValue }
            return coder.containsValue(forKey: key) ? coder.decodeInteger(forKey: key) : 0
        }
        name = text("name")
        address = text("address")
        username = text("username")
        remotePath = text("remotePath")
        port = integer("port")
        protocolCode = integer("protocol")
        // A key file's path when it's one (other forms aren't brought over).
        privateKey = (coder.decodeObject(of: NSString.self, forKey: "privateKey") as String?).flatMap { $0.isEmpty ? nil : $0 }
    }

    func encode(with coder: NSCoder) {}
}

/// TRConnectionGroup: its connections and groups.
final class TransmitGroup: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    let children: [Any]

    init?(coder: NSCoder) {
        children = (coder.decodeObject(of: ServerImport.transmitClasses, forKey: "connections") as? [Any]) ?? []
    }

    func encode(with coder: NSCoder) {}
}

/// Whatever else Transmit archived (history, places): decoded as nothing.
final class ArchivedIgnored: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { true }
    init?(coder: NSCoder) {}
    func encode(with coder: NSCoder) {}
}

private final class StandIns: NSObject, NSKeyedUnarchiverDelegate {
    func unarchiver(_ unarchiver: NSKeyedUnarchiver, cannotDecodeObjectOfClassName name: String, originalClasses classNames: [String]) -> AnyClass? {
        ArchivedIgnored.self
    }
}
