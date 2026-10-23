// Destination containment that holds up against symlinks. Names are already
// kept inside the destination lexically (TransferPlan.isContained, localName);
// this checks the folders on disk too, so a symlink planted in the destination
// tree (by a NAS share, a shared drive, or a link Blit recreated from a copy
// source) can't redirect a write outside the folder the user chose.

import Darwin

public enum SafePath {
    /// A component below the destination folder is a symlink, or not a folder.
    public struct Escape: Error, CustomStringConvertible, Sendable {
        public let path: String
        public let reason: String
        public var description: String { "\(path): \(reason); not followed (it could lead outside the destination folder)" }
    }

    /// Creates the folders between `root` and `path`'s parent that don't exist
    /// yet, refusing to pass through a symlink or a non-folder. `root` itself
    /// (the folder the user chose) may be a symlink; nothing below it may.
    public static func createParents(of path: String, under root: String) throws {
        try walk(parentsOf: path, under: root, create: true)
    }

    /// Creates `directory` (and any missing folders down to it) under `root`,
    /// with the same rules as `createParents(of:under:)`.
    public static func createDirectory(_ directory: String, under root: String) throws {
        try walk(parentsOf: directory + "/.", under: root, create: true)
    }

    /// Throws if a folder between `root` and `path` is a symlink or missing,
    /// or if `path` itself is a symlink. Call just before writing `path`.
    public static func check(_ path: String, under root: String) throws {
        try walk(parentsOf: path, under: root, create: false)
        var info = stat()
        if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
            throw Escape(path: path, reason: "is a symlink")
        }
    }

    private static func walk(parentsOf path: String, under root: String, create: Bool) throws {
        let base = root.hasSuffix("/") && root.count > 1 ? String(root.dropLast()) : root
        guard path.hasPrefix(base + "/") else { throw Escape(path: path, reason: "isn't inside \(base)") }
        var components = path.dropFirst(base.count + 1).split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        components.removeLast()   // the leaf (or the "." of createDirectory)
        var current = base
        for component in components {
            guard !component.isEmpty, component != ".", component != ".." else {
                throw Escape(path: path, reason: "has an unsafe component")
            }
            current += "/" + component
            var info = stat()
            if lstat(current, &info) != 0 {
                guard errno == ENOENT, create else { throw POSIXFailure("check \(current)") }
                if mkdir(current, 0o755) != 0, errno != EEXIST { throw POSIXFailure("create \(current)") }
                guard lstat(current, &info) == 0 else { throw POSIXFailure("check \(current)") }
            }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: continue
            case S_IFLNK: throw Escape(path: current, reason: "is a symlink")
            default: throw Escape(path: current, reason: "isn't a folder")
            }
        }
    }
}
