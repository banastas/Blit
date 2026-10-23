// Gatekeeper's quarantine: browsers mark what they download, and macOS checks
// a marked app or installer the first time it's opened. Blit isn't sandboxed,
// so nothing marks its files for it: downloads are marked here, and copies
// keep the mark their source had.

import Darwin
import Foundation

public enum Quarantine {
    public static let attribute = "com.apple.quarantine"

    /// Marks `path` as downloaded by Blit, from `origin` when known.
    public static func markDownloaded(_ path: String, origin: String? = nil) {
        var url = URL(fileURLWithPath: path)
        var properties: [String: Any] = ["LSQuarantineType": "LSQuarantineTypeOtherDownload", "LSQuarantineAgentName": "Blit"]
        if let origin { properties["LSQuarantineOriginURL"] = origin }
        var values = URLResourceValues()
        values.quarantineProperties = properties
        try? url.setResourceValues(values)
    }

    /// Copies the source's quarantine mark (if it has one) to the destination.
    public static func copy(from source: Int32, to destination: Int32) {
        let size = fgetxattr(source, attribute, nil, 0, 0, 0)
        guard size > 0 else { return }
        var value = [UInt8](repeating: 0, count: size)
        let read = fgetxattr(source, attribute, &value, size, 0, 0)
        guard read > 0 else { return }
        _ = fsetxattr(destination, attribute, value, read, 0, 0)
    }

    /// Whether `path` carries a quarantine mark (for tests and checks).
    public static func isMarked(_ path: String) -> Bool {
        getxattr(path, attribute, nil, 0, 0, XATTR_NOFOLLOW) > 0
    }
}
