// Paths compared by their text. URL.standardizedFileURL asks the disk about
// the path on every call (an access and a stat), and so does
// URL(fileURLWithPath:) without a directory hint (a stat): on a NAS each is a
// network round trip, which queues behind a copy's writes. Blit 0.2.33 froze
// on a slow share that way, looking paths up as its file list drew.

import Foundation

public enum LexicalPath {
    /// `path` with "." and ".." resolved, repeated and trailing slashes
    /// dropped, and /private/var, /private/tmp and /private/etc as /var, /tmp
    /// and /etc: the text alone, never the disk. For keys and comparisons;
    /// other links aren't followed (as standardizedFileURL didn't follow them).
    public static func normalize(_ path: String) -> String {
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
}
