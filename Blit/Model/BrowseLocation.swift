// Where the browser can point: a local folder (including SMB mounts) or a
// folder on a configured server. Remote paths are raw bytes (PRD R3.10).

import BlitSFTP
import Foundation

enum BrowseLocation: Hashable, Codable, Sendable {
    case local(URL)
    case remote(server: UUID, path: [UInt8])

    static func remote(_ server: UUID, _ path: RemotePath) -> BrowseLocation {
        .remote(server: server, path: path.bytes)
    }

    var localURL: URL? {
        if case .local(let url) = self { return url }
        return nil
    }

    var serverID: UUID? {
        if case .remote(let id, _) = self { return id }
        return nil
    }

    var remotePath: RemotePath? {
        if case .remote(_, let bytes) = self { return RemotePath(bytes: bytes) }
        return nil
    }

    /// The folder's own name ("Movies", "downloads"); empty for a server's home.
    var lastComponent: String {
        switch self {
        case .local(let url):
            return url.path == "/" ? "/" : url.lastPathComponent
        case .remote(_, let bytes):
            return bytes.isEmpty ? "" : RemotePath(bytes: bytes).lastComponent.description
        }
    }

    /// One level up, or nil at the top.
    var parent: BrowseLocation? {
        switch self {
        case .local(let url):
            return url.path == "/" ? nil : .local(url.deletingLastPathComponent())
        case .remote(let server, var bytes):
            while bytes.count > 1, bytes.last == UInt8(ascii: "/") { bytes.removeLast() }
            guard !bytes.isEmpty, bytes != [UInt8(ascii: "/")] else { return nil }
            if let slash = bytes.lastIndex(of: UInt8(ascii: "/")) {
                return .remote(server: server, path: slash == 0 ? [UInt8(ascii: "/")] : Array(bytes[..<slash]))
            }
            return .remote(server: server, path: [])
        }
    }

    func appending(_ name: RemotePath) -> BrowseLocation? {
        guard case .remote(let server, let bytes) = self else { return nil }
        return .remote(server, RemotePath(bytes: bytes).appending(name))
    }
}
