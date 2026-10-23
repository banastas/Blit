// Files another app hands Blit (the Send to Blit… Service). Blit runs with Full
// Disk Access, so it can read places the calling app can't; a request naming
// those is refused rather than copied to a folder the caller might read.

import BlitLocal
import Foundation

enum ExternalFiles {
    /// Inside ~/Library, apart from the iCloud Drive and cloud-storage folders
    /// that live there (where files you work with really are).
    static func isPrivateData(_ url: URL, home: String = NSHomeDirectory()) -> Bool {
        let path = LexicalPath.normalize(url.path)
        let library = LexicalPath.normalize(home + "/Library")
        guard path == library || path.hasPrefix(library + "/") else { return false }
        let shared = ["Mobile Documents", "CloudStorage"].map { library + "/" + $0 }
        return !shared.contains { path == $0 || path.hasPrefix($0 + "/") }
    }
}
