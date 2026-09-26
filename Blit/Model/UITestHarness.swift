// Debug builds only: a self-test for right-click menus, since they can't be
// checked from outside the app without Accessibility access. Launch with
// `-BlitRightClickTest /path/to/log.txt`: Blit opens a small temporary folder,
// sends itself right-clicks at a few points, writes which menu opened at each
// (or none), then goes back.

#if DEBUG
import AppKit
import SwiftUI

@MainActor
enum UITestHarness {
    /// `-BlitRenderStatusIcons out.png`: the sidebar status icons at 8×, light and dark.
    static func renderStatusIconsIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "BlitRenderStatusIcons") else { return }
        let row = { (scheme: ColorScheme) in
            HStack(spacing: 14) {
                ForEach(0..<5) { PixelSignal(lit: $0) }
                Image(nsImage: PixelGlyph.cross.image(size: 10.5)).foregroundStyle(Color.failure)
            }
            .padding(6)
            .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.93))
            .environment(\.colorScheme, scheme)
        }
        let extras = { (scheme: ColorScheme) in
            HStack(spacing: 14) {
                PixelSpinner(cell: 1.5)
                Image(nsImage: PixelArt.image(PixelArt.shield, cell: 1)).foregroundStyle(.tertiary)
                Image(nsImage: PixelArt.image(PixelArt.menuBarArrow(frame: nil), cell: 1.5))
                ForEach(0..<3) { Image(nsImage: PixelArt.image(PixelArt.menuBarArrow(frame: $0), cell: 1.5)) }
                Text("name.mkv").font(.system(size: 11))
                Image(nsImage: PixelGlyph.check.image(size: 9)).foregroundStyle(.secondary)
                PixelMarchingAnts(cell: 1.5).frame(width: 40, height: 16)
            }
            .padding(6)
            .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.93))
            .environment(\.colorScheme, scheme)
        }
        let renderer = ImageRenderer(content: VStack(spacing: 0) { row(.light); row(.dark); extras(.light); extras(.dark) })
        renderer.scale = 8
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
        // The About window, at 2×.
        let about = ImageRenderer(content: AboutView())
        about.scale = 2
        if let image = about.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-about.png")))
        }
        // The Dock tile mid-transfer, then done.
        DockProgress.shared.update(0.42)
        if let view = NSApp.dockTile.contentView {
            view.frame = NSRect(x: 0, y: 0, width: 256, height: 256)
            if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-dock.png")))
            }
        }
        DockProgress.shared.finish(verified: true)
        if let view = NSApp.dockTile.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-dock-done.png")))
        }
    }

    /// `-BlitQueueTest <log> -BlitQueueTestDest <folder on another volume>`:
    /// exercises pause / resume / pause all / cancel / retry on real copies and
    /// renders the HUD's queue panel next to the log.
    static func runQueueTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitQueueTest"),
              let destPath = UserDefaults.standard.string(forKey: "BlitQueueTestDest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        @MainActor func state(_ job: TransferJob) -> String { "\(job.title): \(job.status) \(job.filesFinished)/\(job.fileCount)" }
        Task { @MainActor in
            let fm = FileManager.default
            let src = fm.temporaryDirectory.appendingPathComponent("blit-queue-src")
            try? fm.removeItem(at: src)
            for name in ["A", "B"] {
                let folder = src.appendingPathComponent(name)
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                for i in 0..<3 {
                    let file = folder.appendingPathComponent("\(name)\(i).bin")
                    fm.createFile(atPath: file.path, contents: nil)
                    if let handle = try? FileHandle(forWritingTo: file) {
                        let chunk = Data((0..<(8 << 20)).map { _ in UInt8.random(in: 0...255) })
                        for _ in 0..<64 { handle.write(chunk) }   // 512 MB
                        try? handle.close()
                    }
                }
            }
            let dest = URL(fileURLWithPath: destPath)
            try? fm.removeItem(at: dest)
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            lines.append("sources ready")
            _ = transfers.enqueue([.local(src.appendingPathComponent("A"))], to: .local(dest), destinationName: "dest")
            _ = transfers.enqueue([.local(src.appendingPathComponent("B"))], to: .local(dest), destinationName: "dest")
            let a = transfers.transferJobs[transfers.transferJobs.count - 2], b = transfers.transferJobs[transfers.transferJobs.count - 1]
            @MainActor func wait(_ what: String, _ condition: () -> Bool) async {
                for _ in 0..<600 where !condition() { try? await Task.sleep(for: .milliseconds(50)) }
                lines.append("\(condition() ? "ok" : "TIMEOUT") \(what) · \(state(a)) · \(state(b))")
            }
            await wait("A running") { a.status == .running && a.transferred > 0 }
            transfers.pause(a)
            await wait("A paused") { a.status == .paused }
            await wait("B running while A paused") { b.status == .running }
            // Render the HUD with its queue panel while things are in flight.
            let renderer = ImageRenderer(content: TransferHUD(job: b).environment(transfers).frame(width: 1100))
            renderer.scale = 2
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: logPath.replacingOccurrences(of: ".txt", with: "-hud.png")))
            }
            transfers.pauseAll()
            await wait("pause all") { b.status == .paused && transfers.queuePaused }
            transfers.resumeAll()
            await wait("resume all: something running") { a.isActive || b.isActive }
            let running = a.isActive ? a : b
            transfers.cancel(running)
            await wait("cancelled") { running.status == .cancelled }
            transfers.retry(running)
            await wait("all finished") {
                transfers.transferJobs.suffix(2).allSatisfy { $0.status == .finished }
            }
            let copied = ((try? fm.subpathsOfDirectory(atPath: dest.path)) ?? []).filter { $0.hasSuffix(".bin") }.sorted()
            var identical = 0
            for path in copied {
                let name = (path as NSString).lastPathComponent
                let original = src.appendingPathComponent(String(name.prefix(1))).appendingPathComponent(name)
                if fm.contentsEqual(atPath: original.path, andPath: dest.appendingPathComponent(path).path) { identical += 1 }
            }
            let parts = ((try? fm.subpathsOfDirectory(atPath: dest.path)) ?? []).filter { $0.hasSuffix(".blitpart") }
            lines.append("copied \(copied.count) files, \(identical) identical, \(parts.count) part files left")
            lines.append("done")
            try? fm.removeItem(at: src)
        }
    }

    static func runIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitRightClickTest") else { return }
        var lines: [String] = ["started"] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        lines.append("armed")
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            lines.append("running")

            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("blit-right-click-test")
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: folder.appendingPathComponent("one.txt").path, contents: Data("x".utf8))
            guard let browser = BrowserModel.active, let window = BrowserModel.activeWindow else {
                lines.append("no active browser or window")
                return
            }
            // Show the test folder (retrying: launch can restore another location over it).
            for _ in 0..<20 {
                if browser.current?.localURL?.standardizedFileURL.path != folder.standardizedFileURL.path {
                    browser.open(.local(folder))
                }
                try? await Task.sleep(for: .milliseconds(500))
                if browser.rows.contains(where: { $0.name == "one.txt" }) { break }
            }
            lines.append("showing \(browser.current?.lastComponent ?? "nil") · \(browser.rows.count) rows")
            window.makeKeyAndOrderFront(nil)

            var opened: String?
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
                                                                  object: nil, queue: nil) { note in
                nonisolated(unsafe) let menu = note.object as? NSMenu
                MainActor.assumeIsolated {
                    opened = menu?.items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " | ") ?? "?"
                    // Close it shortly after tracking starts (in the menu's run loop mode).
                    let timer = Timer(timeInterval: 0.3, repeats: false) { _ in
                        MainActor.assumeIsolated { menu?.cancelTrackingWithoutAnimation() }
                    }
                    RunLoop.main.add(timer, forMode: .eventTracking)
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            let content = window.contentLayoutRect
            let sidebarWidth: CGFloat = 210
            let listX = content.minX + sidebarWidth + (content.width - sidebarWidth) * 0.5
            let points: [(String, NSPoint)] = [
                ("file row", NSPoint(x: listX, y: content.maxY - 28 - 12)),
                ("empty list space", NSPoint(x: listX, y: content.minY + content.height * 0.45)),
                ("sidebar upper", NSPoint(x: content.minX + 80, y: content.maxY - 60)),
                ("sidebar middle", NSPoint(x: content.minX + 80, y: content.midY)),
            ]
            lines.append("window \(Int(window.frame.width))×\(Int(window.frame.height)), content \(content)")
            for (label, point) in points {
                opened = nil
                lines.append("sending \(label)")
                for type in [NSEvent.EventType.rightMouseDown] {
                    guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: window.windowNumber, context: nil,
                                                         eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                    // Through the event queue, like a real click (sending straight to the
                    // window leaves NSApp.currentEvent dangling).
                    NSApp.postEvent(event, atStart: false)
                }
                lines.append("sent \(label)")
                try? await Task.sleep(for: .milliseconds(1200))
                lines.append("\(label) @ \(Int(point.x)),\(Int(point.y)): \(opened ?? "NO MENU")")
            }
            // Inline rename: Return-style start, name-only selection, type, Return.
            opened = nil
            browser.reload()
            try? await Task.sleep(for: .seconds(1))
            if let item = browser.rows.first(where: { $0.name == "one.txt" }) {
                browser.beginRename(item)
                try? await Task.sleep(for: .seconds(1))
                let editor = window.firstResponder as? NSTextView
                lines.append("rename: responder \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil") · text \(editor?.string ?? "-") · selected \(editor.map { NSStringFromRange($0.selectedRange()) } ?? "-")")
                if let editor {
                    // ← and → must move the cursor while editing (not expand/collapse rows).
                    for (keyCode, arrow) in [(UInt16(124), "\u{F703}"), (UInt16(123), "\u{F702}")] {
                        let before = editor.selectedRange()
                        if let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
                                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil,
                                                      characters: arrow, charactersIgnoringModifiers: arrow,
                                                      isARepeat: false, keyCode: keyCode) {
                            NSApp.postEvent(key, atStart: false)
                        }
                        try? await Task.sleep(for: .milliseconds(400))
                        lines.append("rename: \(keyCode == 124 ? "→" : "←") \(NSStringFromRange(before)) → \(NSStringFromRange(editor.selectedRange()))")
                    }
                    editor.selectAll(nil)
                    editor.insertText("renamed", replacementRange: NSRange(location: 0, length: 3))
                    if let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                    timestamp: ProcessInfo.processInfo.systemUptime,
                                                    windowNumber: window.windowNumber, context: nil,
                                                    characters: "\r", charactersIgnoringModifiers: "\r",
                                                    isARepeat: false, keyCode: 36) {
                        NSApp.postEvent(enter, atStart: false)
                    }
                    try? await Task.sleep(for: .seconds(1.5))
                }
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                lines.append("rename: on disk \(names.sorted()) · renaming \(browser.renaming == nil ? "ended" : "still on")")
                // Put it back for the next run.
                for name in names where name != "one.txt" {
                    try? FileManager.default.moveItem(at: folder.appendingPathComponent(name),
                                                      to: folder.appendingPathComponent("one.txt"))
                }
            } else {
                lines.append("rename: one.txt not listed")
            }
            browser.goBack()
        }
    }
}
#endif
