// Reads a video file's header for the Video column: Matroska (MKV, WebM)
// with Blit's own reader, MP4 and QuickTime through AVFoundation. Only the
// header is read (a 64 KB chunk or two for Matroska), never the frames.

import Foundation

public enum VideoProbe {
    /// The extensions read.
    public static let fileExtensions: Set<String> = ["mkv", "mk3d", "webm", "mp4", "m4v", "mov"]

    public static func handles(_ url: URL) -> Bool { fileExtensions.contains(url.pathExtension.lowercased()) }

    /// What `url`'s header says; nil if it isn't a video Blit can read.
    public static func probe(_ url: URL) async -> VideoInfo? {
        switch url.pathExtension.lowercased() {
        case "mkv", "mk3d", "webm":
            // Plain blocking reads (a share may take a while), off the concurrency pool.
            return await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    let info = (try? FileSource(url: url)).flatMap { try? Matroska.read($0) }
                    continuation.resume(returning: info)
                }
            }
        case "mp4", "m4v", "mov":
            return await MP4Probe.probe(url)
        default:
            return nil
        }
    }
}
