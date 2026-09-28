// Space on a video or audio file Quick Look can't play (MKV, WebM, AVI, or an
// MP4 in a codec Apple doesn't decode): when mpv is installed, Blit opens it in
// mpv as a floating preview window instead. Whether Quick Look can play it is
// asked of AVFoundation (what Quick Look plays with) for that very file.
// Space or Escape closes it, as Quick Look does (Blit gives mpv its own key
// bindings for the preview); ← → seek 10 s, ↑ ↓ a minute, P or a click
// pauses, M mutes. mpv's own settings (audio and subtitle languages) still
// apply; fullscreen and resume positions are turned off for the preview.

import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

@MainActor
enum MpvPreview {
    private static var process: Process?

    /// Formats to consider even when no app has declared their type (a
    /// Homebrew mpv declares none). Whether to use mpv is still decided per file.
    private static let extensions: Set<String> = [
        "mkv", "mk3d", "mka", "webm", "avi", "divx", "flv", "f4v", "wmv", "asf", "ogv", "ogm", "ogg",
        "opus", "m2ts", "mts", "ts", "vob", "rm", "rmvb", "nut",
    ]

    /// mpv's command-line binary: the app from mpv.io, else Homebrew's.
    static var executable: URL? {
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.mpv") {
            let binary = app.appendingPathComponent("Contents/MacOS/mpv")
            if FileManager.default.isExecutableFile(atPath: binary.path) { return binary }
        }
        return ["/opt/homebrew/bin/mpv", "/usr/local/bin/mpv"]
            .first(where: FileManager.default.isExecutableFile(atPath:))
            .map { URL(fileURLWithPath: $0) }
    }

    /// A local video or audio file mpv can open: worth asking whether Quick
    /// Look can play it (images and documents go straight to Quick Look).
    static func mightHandle(_ url: URL) -> Bool {
        guard url.isFileURL, let executable else { return false }
        let ext = url.pathExtension.lowercased()
        let type = UTType(filenameExtension: ext)
        guard extensions.contains(ext) || type?.conforms(to: .audiovisualContent) == true else { return false }
        // The mpv app: Launch Services knows what it opens. Homebrew's: assume media.
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.mpv"),
           executable.path.hasPrefix(app.path) {
            return extensions.contains(ext)
                || NSWorkspace.shared.urlsForApplications(toOpen: url).contains { $0.standardizedFileURL == app.standardizedFileURL }
        }
        return true
    }

    /// Whether Space should open `url` in mpv: mpv can open it and Quick Look
    /// (AVFoundation) can't play this file. A file that doesn't answer within
    /// 3 s (a slow share) goes to Quick Look as before.
    static func shouldPreview(_ url: URL) async -> Bool {
        guard mightHandle(url) else { return false }
        let playable = await withTaskGroup(of: Bool?.self) { group in
            group.addTask { try? await AVURLAsset(url: url).load(.isPlayable) }
            group.addTask {
                try? await Task.sleep(for: .seconds(3))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        // nil: timed out; leave it to Quick Look.
        return playable == false
    }

    static var isShowing: Bool { process?.isRunning == true }

    /// The arguments for previewing `url` (tests read them too).
    static func arguments(for url: URL, inputConf: URL) -> [String] {
        [
            "--input-conf=\(inputConf.path)",
            "--no-terminal",
            "--force-window=immediate",
            "--ontop",
            "--autofit=60%x60%",
            "--geometry=50%:50%",
            "--fs=no",
            "--keep-open=no",
            "--resume-playback=no",
            "--save-position-on-quit=no",
            "--focus-on=open",
            "--title=\(url.lastPathComponent) — Blit Preview",
            "--",
            url.path,
        ]
    }

    /// The preview's keys: Space and Escape close it, as in Quick Look.
    static let bindings = """
        SPACE quit
        ESC quit
        q quit
        RIGHT seek 10
        LEFT seek -10
        UP seek 60
        DOWN seek -60
        p cycle pause
        MBTN_LEFT cycle pause
        m cycle mute
        """

    private static func inputConf() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Blit mpv", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("input.conf")
        try (bindings + "\n").write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    /// Opens `url` in an mpv preview window (closing one already open).
    /// Returns a problem to show, or nil.
    @discardableResult
    static func show(_ url: URL) -> String? {
        close()
        guard let executable else { return "mpv isn't installed." }
        do {
            let task = Process()
            task.executableURL = executable
            task.arguments = arguments(for: url, inputConf: try inputConf())
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            task.terminationHandler = { ended in
                Task { @MainActor in
                    guard process === ended else { return }
                    process = nil
                    // Closed from mpv (Space, Escape): back to the list, as after Quick Look.
                    NSApp.activate()
                }
            }
            try task.run()
            process = task
            return nil
        } catch {
            return "Couldn't open mpv: \(error.localizedDescription)"
        }
    }

    static func close() {
        guard let running = process else { return }
        process = nil
        if running.isRunning { running.terminate() }
    }
}
