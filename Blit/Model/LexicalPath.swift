// Paths compared by their text (BlitLocal's LexicalPath): never asking the
// disk, as URL.standardizedFileURL and URL(fileURLWithPath:) do. Called for
// every row as the file list drew, those froze the window on a slow share.

import BlitLocal
import Foundation

extension URL {
    /// The file path with "." and ".." resolved, repeated and trailing slashes
    /// dropped, and /private/var, /private/tmp and /private/etc as /var, /tmp
    /// and /etc: the text alone, never the disk. For keys and comparisons.
    var lexicalPath: String { LexicalPath.normalize(path) }

    /// lexicalPath split as pathComponents splits a path: "/" first, then each name.
    var lexicalComponents: [String] {
        ["/"] + lexicalPath.split(separator: "/").map(String.init)
    }

    /// Whether this path is `other` or inside it, by text.
    func lexicallyInside(_ other: URL) -> Bool {
        let path = lexicalPath, root = other.lexicalPath
        return path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }
}
