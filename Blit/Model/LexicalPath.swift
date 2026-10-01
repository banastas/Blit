// Paths compared by their text. URL.standardizedFileURL asks the disk about
// the path on every call (an access and a stat), and so does
// URL(fileURLWithPath:) without a directory hint (a stat): on a NAS each is a
// network round trip. Called for every row as the file list drew (the
// verified badge's lookup), they froze the window on a slow share for as long
// as a transfer kept the list redrawing.

import Foundation

extension URL {
    /// The file path with "." and ".." resolved, repeated and trailing slashes
    /// dropped, and /private/var, /private/tmp and /private/etc as /var, /tmp
    /// and /etc: the text alone, never the disk. For keys and comparisons;
    /// other links aren't followed (as standardizedFileURL didn't follow them).
    var lexicalPath: String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        // /var, /tmp and /etc are links into /private: the short form, as
        // standardizedFileURL gave (it checked the disk to decide).
        if parts.count >= 2, parts[0] == "private", ["var", "tmp", "etc"].contains(parts[1]) { parts.removeFirst() }
        return "/" + parts.joined(separator: "/")
    }

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
