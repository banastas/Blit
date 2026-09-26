// Debug builds only: a self-test for right-click menus, since they can't be
// checked from outside the app without Accessibility access. Launch with
// `-BlitRightClickTest /path/to/log.txt`: Blit opens a small temporary folder,
// sends itself right-clicks at a few points, writes which menu opened at each
// (or none), then goes back.

#if DEBUG
import AppKit
import BlitRemote
import BlitSFTP
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
                Image(nsImage: PixelArt.image(PixelArt.shield, cell: 1)).foregroundStyle(.secondary)   // as in the sidebar
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
        DockProgress.shared.finish(.verified)
        if let view = NSApp.dockTile.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-dock-done.png")))
        }
        DockProgress.shared.finish(.failed)
        if let view = NSApp.dockTile.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "-dock-failed.png")))
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

    /// `-BlitSpaceTest <log> -BlitSpaceTestDest <mount point>`: fills the volume,
    /// queues a copy that doesn't fit, checks it waits (not fails), frees space,
    /// and checks it then finishes.
    static func runSpaceTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitSpaceTest"),
              let mount = UserDefaults.standard.string(forKey: "BlitSpaceTestDest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            let fm = FileManager.default
            func write(_ url: URL, megabytes: Int) {
                fm.createFile(atPath: url.path, contents: nil)
                guard let handle = try? FileHandle(forWritingTo: url) else { return }
                let chunk = Data((0..<(1 << 20)).map { _ in UInt8.random(in: 0...255) })
                for _ in 0..<megabytes { handle.write(chunk) }
                try? handle.close()
            }
            let src = fm.temporaryDirectory.appendingPathComponent("blit-space-src")
            try? fm.removeItem(at: src)
            try? fm.createDirectory(at: src, withIntermediateDirectories: true)
            write(src.appendingPathComponent("big.bin"), megabytes: 400)
            let filler = URL(fileURLWithPath: mount).appendingPathComponent("filler.bin")
            let free = TransferManager.freeSpace(at: URL(fileURLWithPath: mount)) ?? 0
            write(filler, megabytes: max(0, Int(free >> 20) - 700))
            lines.append("free after filler: \(TransferManager.freeSpace(at: URL(fileURLWithPath: mount)).map { $0 >> 20 } ?? 0) MB")
            let dest = URL(fileURLWithPath: mount).appendingPathComponent("dest")
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            _ = transfers.enqueue([.local(src.appendingPathComponent("big.bin"))], to: .local(dest), destinationName: "dest")
            guard let job = transfers.transferJobs.last else { return }
            for _ in 0..<200 {
                if case .waitingForSpace = job.status { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            lines.append("status while full: \(job.status)")
            lines.append("last note: \(job.log.last?.text ?? "-")")
            try? fm.removeItem(at: filler)
            lines.append("filler removed")
            for _ in 0..<600 where job.status != .finished {
                if case .failed = job.status { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let same = fm.contentsEqual(atPath: src.appendingPathComponent("big.bin").path,
                                        andPath: dest.appendingPathComponent("big.bin").path)
            lines.append("status after freeing: \(job.status) · copy identical: \(same)")
            lines.append("done")
            try? fm.removeItem(at: src)
        }
    }

    /// `-BlitExistsTest <log>`: runs each ExistsRule against a destination
    /// holding an identical file, a same-size different file and a
    /// different-size file, and checks what ends up on disk.
    static func runExistsTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitExistsTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-exists-test")
            try? fm.removeItem(at: root)
            let src = root.appendingPathComponent("src/Pack")
            try? fm.createDirectory(at: src, withIntermediateDirectories: true)
            let original = Data(repeating: 1, count: 1 << 20), other = Data(repeating: 2, count: 1 << 20)
            for name in ["same", "diff", "grow"] { try? original.write(to: src.appendingPathComponent("\(name).bin")) }
            let saved = UserDefaults.standard.string(forKey: "existsRule")
            for rule in ExistsRule.allCases {
                let dest = root.appendingPathComponent("dest-\(rule.rawValue)")
                let existing = dest.appendingPathComponent("Pack")
                try? fm.createDirectory(at: existing, withIntermediateDirectories: true)
                try? original.write(to: existing.appendingPathComponent("same.bin"))
                try? other.write(to: existing.appendingPathComponent("diff.bin"))
                try? Data(repeating: 3, count: 1000).write(to: existing.appendingPathComponent("grow.bin"))
                UserDefaults.standard.set(rule.rawValue, forKey: "existsRule")
                _ = transfers.enqueue([.local(src)], to: .local(dest), destinationName: rule.rawValue)
                guard let job = transfers.transferJobs.last else { continue }
                for _ in 0..<300 where job.isActive || job.status == .queued { try? await Task.sleep(for: .milliseconds(100)) }
                let files = ((try? fm.contentsOfDirectory(atPath: existing.path)) ?? []).sorted()
                let described = files.map { name -> String in
                    let data = (try? Data(contentsOf: existing.appendingPathComponent(name))) ?? Data()
                    return "\(name)=\(data == original ? "source" : data == other ? "other" : data.count == 1000 ? "short" : "?")"
                }
                let outcomes = job.log.map(\.text).filter { $0.contains(".BIN") }.map { String($0.prefix(60)) }
                lines.append("\(rule.rawValue): \(job.status) · \(described.joined(separator: " "))")
                for outcome in outcomes { lines.append("    \(outcome)") }
            }
            UserDefaults.standard.set(saved, forKey: "existsRule")
            lines.append("done")
            try? fm.removeItem(at: root)
        }
    }

    /// `-BlitStructureTest <log> -BlitStructureTestDest <folder on another volume>`:
    /// copies and moves a tree with empty folders and symlinks (PRD R3.1).
    static func runStructureTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitStructureTest"),
              let destPath = UserDefaults.standard.string(forKey: "BlitStructureTestDest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-structure")
            try? fm.removeItem(at: root)
            func makeTree(_ name: String) -> URL {
                let pack = root.appendingPathComponent(name)
                try? fm.createDirectory(at: pack.appendingPathComponent("Sample"), withIntermediateDirectories: true)
                try? fm.createDirectory(at: pack.appendingPathComponent("a/b"), withIntermediateDirectories: true)
                try? Data("movie".utf8).write(to: pack.appendingPathComponent("movie.mkv"))
                try? fm.createSymbolicLink(atPath: pack.appendingPathComponent("link.mkv").path, withDestinationPath: "movie.mkv")
                try? fm.createSymbolicLink(atPath: pack.appendingPathComponent("dangling").path, withDestinationPath: "/nowhere/at/all")
                return pack
            }
            func describe(_ url: URL) -> String {
                let items = ((try? fm.subpathsOfDirectory(atPath: url.path)) ?? []).sorted()
                return items.map { item -> String in
                    let path = url.appendingPathComponent(item).path
                    if let target = try? fm.destinationOfSymbolicLink(atPath: path) { return "\(item)->\(target)" }
                    var isDir: ObjCBool = false
                    fm.fileExists(atPath: path, isDirectory: &isDir)
                    return isDir.boolValue ? "\(item)/" : item
                }.joined(separator: " ")
            }
            let dest = URL(fileURLWithPath: destPath)
            try? fm.removeItem(at: dest)
            try? fm.createDirectory(at: dest.appendingPathComponent("copy"), withIntermediateDirectories: true)
            try? fm.createDirectory(at: dest.appendingPathComponent("move"), withIntermediateDirectories: true)
            let copySource = makeTree("CopyPack"), moveSource = makeTree("MovePack")
            lines.append("source: \(describe(copySource))")
            _ = transfers.enqueue([.local(copySource)], to: .local(dest.appendingPathComponent("copy")), destinationName: "copy")
            _ = transfers.enqueue([.local(moveSource)], to: .local(dest.appendingPathComponent("move")), destinationName: "move", move: true)
            for _ in 0..<300 where transfers.transferJobs.suffix(2).contains(where: { $0.isActive || $0.status == .queued }) {
                try? await Task.sleep(for: .milliseconds(100))
            }
            for job in transfers.transferJobs.suffix(2) {
                lines.append("\(job.title): \(job.status) · \(job.failures)")
                for line in job.log { lines.append("    \(line.text.prefix(110))") }
            }
            lines.append("copied: \(describe(dest.appendingPathComponent("copy/CopyPack")))")
            lines.append("moved: \(describe(dest.appendingPathComponent("move/MovePack")))")
            lines.append("move source still exists: \(fm.fileExists(atPath: moveSource.path))")
            lines.append("done")
            try? fm.removeItem(at: root)
        }
    }

    /// `-BlitUndoTest <log>`: rename, move and trash in a temporary folder,
    /// each followed by Edit › Undo, checking the disk after each step.
    /// `-BlitPartialTest <log>`: part files in the list (kinds, progress, resume
    /// problem) and trashing a part takes its `.state` sidecar with it.
    static func runPartialTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitPartialTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let browser = BrowserModel.active else { return lines.append("no browser") }
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-partial-test")
            try? fm.removeItem(at: root)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            fm.createFile(atPath: root.appendingPathComponent("movie.mkv.blitpart").path, contents: Data(count: 1000))
            let state = #"{"version":1,"remotePath":"\#(Data("/files/movie.mkv".utf8).base64EncodedString())","size":1000,"modificationTime":5,"done":{"ranges":[[0,370]]},"host":"nowhere.invalid","port":22,"username":"u"}"#
            fm.createFile(atPath: root.appendingPathComponent("movie.mkv.blitpart.state").path, contents: Data(state.utf8))
            fm.createFile(atPath: root.appendingPathComponent("copy.bin.blitpart").path, contents: Data(count: 10))
            browser.open(.local(root))
            for _ in 0..<20 where browser.items.count < 3 { try? await Task.sleep(for: .milliseconds(200)) }
            for item in browser.items.sorted(by: { $0.name < $1.name }) {
                lines.append("\(item.name) · \(item.kind) · partial \(item.partial.map { "\($0.done)/\($0.size) \($0.remotePath)" } ?? "none")")
            }
            if let part = browser.items.first(where: { $0.name == "movie.mkv.blitpart" }) {
                lines.append("resume: \(browser.resumeProblem(part) ?? "ok")")
                browser.requestDelete([part])
                try? await Task.sleep(for: .seconds(2))
                lines.append("left: \(((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted().joined(separator: " "))")
            }
            lines.append("done")
        }
    }

    /// `-BlitSortTest <log>`: sort order is remembered per folder.
    static func runSortTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitSortTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let browser = BrowserModel.active else { return lines.append("no browser") }
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-sort-test")
            let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
            for dir in [a, b] { try? fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            @MainActor func state(_ label: String) {
                let order = browser.sortOrder.first?.order == .forward ? "asc" : "desc"
                lines.append("\(label): \(browser.sortColumn?.rawValue ?? "?") \(order)")
            }
            func settle() async { try? await Task.sleep(for: .milliseconds(400)) }
            browser.open(.local(a)); await settle(); state("a first")
            browser.sort(by: .name); state("a by name")
            browser.open(.local(b)); await settle(); state("b")
            browser.sortOrder = [SortColumn.size.comparator(.forward)]; state("b by size asc")
            browser.goBack(); await settle(); state("back to a")
            browser.goForward(); await settle(); state("forward to b")
            browser.sort(by: .modified)
            let saved = (UserDefaults.standard.dictionary(forKey: "sortOrders") ?? [:]).keys.filter { $0.contains("blit-sort-test") }
            lines.append("remembered after resetting b: \(saved.map { ($0 as NSString).lastPathComponent }.sorted())")
            browser.open(.local(a)); await settle()
            browser.sort(by: .modified)
            try? fm.removeItem(at: root)
            lines.append("done")
        }
    }

    /// `-BlitRenderStrip out.png`: the condensed strip and the menu bar panel
    /// for a running job with one idle connection, and one with warnings.
    static func renderStripIfRequested(transfers: TransferManager) {
        guard let path = UserDefaults.standard.string(forKey: "BlitRenderStrip") else { return }
        func job(_ failures: [String]) -> TransferJob {
            let job = TransferJob(kind: .copy, sources: [.local(URL(fileURLWithPath: "/tmp/a.mkv"))],
                                  destination: URL(fileURLWithPath: "/tmp"), title: "SOME.PACK.2160P", destinationName: "Incoming")
            job.persistent = false
            job.status = failures.isEmpty ? .running : .finished
            job.fileCount = 26
            job.filesFinished = 7
            job.totalBytes = 1
            job.connections = 3
            job.link = "SFTP"
            job.connectionRates = [9, 0, 7]
            job.failures = failures
            return job
        }
        let running = job([]), failed = job(["a.mkv: SHA-256 mismatch"])
        transfers.notice("Can't put a folder inside itself.", action: "MOVE", place: "Incoming")
        transfers.notice("“untitled folder” already exists in “Movies”.", action: "NEW FOLDER")
        let notices = transfers.jobs.suffix(2)
        let content = VStack(spacing: 8) {
            TransferStrip(job: running).frame(width: 900)
            TransferStrip(job: failed).frame(width: 900)
            ForEach(Array(notices), id: \.id) { TransferStrip(job: $0).frame(width: 900) }
            MenuBarTransfer(job: failed).frame(width: 296)
        }
        .padding(10)
        .background(Color(white: 0.2))
        .environment(transfers)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    /// `-BlitHUDKeysTest <log>` (with -BlitFakeTransfer YES): Escape collapses the
    /// full HUD and ⇧⌘T toggles it, sent as real key events.
    static func runHUDKeysTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitHUDKeysTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard let window = BrowserModel.activeWindow else { return lines.append("no window") }
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            try? await Task.sleep(for: .milliseconds(500))
            @MainActor func press(_ characters: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) async {
                if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                                                timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil,
                                                characters: characters, charactersIgnoringModifiers: characters.lowercased(),
                                                isARepeat: false, keyCode: keyCode) {
                    NSApp.postEvent(event, atStart: false)
                }
                try? await Task.sleep(for: .milliseconds(600))
            }
            lines.append("start: expanded \(transfers.isExpanded) · active \(NSApp.isActive) · key window is main \(NSApp.keyWindow === window)")
            for item in NSApp.mainMenu?.items.flatMap({ $0.submenu?.items ?? [] }) ?? [] where item.title.contains("Transfer Details") || item.title.contains("Toolbar") {
                lines.append("menu: \(item.title) key \(item.keyEquivalent) mods \(item.keyEquivalentModifierMask.rawValue) enabled \(item.isEnabled)")
            }
            await press("\u{1B}", 53)
            lines.append("after Escape: expanded \(transfers.isExpanded)")
            // Key events only reach the active app: run this with Blit frontmost.
            @MainActor func toggleDetails() async { await press("T", 17, [.command, .shift]) }
            await toggleDetails()
            lines.append("after ⇧⌘T: expanded \(transfers.isExpanded)")
            await toggleDetails()
            lines.append("after ⇧⌘T again: expanded \(transfers.isExpanded)")
            lines.append("done")
        }
    }

    /// `-BlitNoticeTest <log>`: problems reach the strip exactly once, with no alert:
    /// a tracked failure (duplicating a vanished file) and a precondition
    /// (putting a folder inside itself).
    static func runNoticeTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitNoticeTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let browser = BrowserModel.active else { return lines.append("no browser") }
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-notice-test")
            try? fm.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
            @MainActor func failed() -> [String] { transfers.jobs.filter { $0.isOperation && !$0.failures.isEmpty }.map { "\($0.title): \($0.failures.joined(separator: " | "))" } }
            let ghost = FileItem(location: .local(root.appendingPathComponent("gone.txt")), name: "gone.txt", isDirectory: false,
                                 modified: .now, size: 1, kind: "Text")
            browser.duplicate([ghost])
            try? await Task.sleep(for: .seconds(1.5))
            lines.append("after duplicate of a missing file: \(failed())")
            transfers.dismissFinished()
            let folder = BrowseLocation.local(root.appendingPathComponent("folder"))
            browser.drop([folder], into: folder, name: "folder", copy: false)
            try? await Task.sleep(for: .seconds(1.5))
            lines.append("after folder into itself: \(failed())")
            transfers.dismissFinished()
            try? fm.removeItem(at: root)
            lines.append("done")
        }
    }

    /// `-BlitStatusTest <log>`: the Status column's lookup for a local copy,
    /// on source and destination rows, queued and finished.
    static func runStatusTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitStatusTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-status-test")
            try? fm.removeItem(at: root)
            let pack = root.appendingPathComponent("src/Pack"), dest = root.appendingPathComponent("dst")
            try? fm.createDirectory(at: pack, withIntermediateDirectories: true)
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            for name in ["a.bin", "b.bin"] { fm.createFile(atPath: pack.appendingPathComponent(name).path, contents: Data(count: 1 << 20)) }
            @MainActor func show(_ label: String, _ folder: URL) {
                let items = (try? BrowserModel.listLocal(folder, showHidden: false)) ?? []
                for item in items.sorted(by: { $0.name < $1.name }) {
                    let s = transfers.status(for: item)
                    lines.append("\(label) \(item.name): \(s.map { "\($0.glyph.map(String.init) ?? "")\($0.text)" } ?? "—")")
                }
            }
            if let message = transfers.enqueue([.local(pack)], to: .local(dest), destinationName: "dst") { lines.append("enqueue: \(message)") }
            show("queued src", root.appendingPathComponent("src"))
            show("queued src/Pack", pack)
            for _ in 0..<60 where transfers.transferJobs.last?.status != .finished { try? await Task.sleep(for: .milliseconds(250)) }
            show("done src", root.appendingPathComponent("src"))
            show("done src/Pack", pack)
            show("done dst", dest)
            show("done dst/Pack", dest.appendingPathComponent("Pack"))
            transfers.dismissFinished()
            show("dismissed dst/Pack", dest.appendingPathComponent("Pack"))
            try? fm.removeItem(at: root)
            lines.append("done")
        }
    }

    /// `-BlitRetryNowTest <log>`: a copy into a read-only folder waits to retry;
    /// Retry Now tries again at once instead of after the backoff.
    static func runRetryNowTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitRetryNowTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-retry-test")
            try? fm.removeItem(at: root)
            let pack = root.appendingPathComponent("src/Pack"), dest = root.appendingPathComponent("dst")
            try? fm.createDirectory(at: pack, withIntermediateDirectories: true)
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            fm.createFile(atPath: pack.appendingPathComponent("a.bin").path, contents: Data(count: 1 << 16))
            try? fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dest.path)
            _ = transfers.enqueue([.local(pack)], to: .local(dest), destinationName: "dst")
            guard let job = transfers.transferJobs.last else { return lines.append("no job") }
            @MainActor func describe() -> String {
                switch job.status {
                case .waiting(let until, let reason): "waiting \(max(0, Int(until.timeIntervalSinceNow)))s · \(reason) · attempt \(job.attempt)"
                default: "\(job.status) · attempt \(job.attempt)"
                }
            }
            @MainActor func waitUntil(_ seconds: Double, _ done: () -> Bool) async {
                let end = Date().addingTimeInterval(seconds)
                while Date() < end, !done() { try? await Task.sleep(for: .milliseconds(100)) }
            }
            await waitUntil(15) { if case .waiting = job.status { true } else { false } }
            lines.append("first failure: \(describe())")
            let start = Date()
            transfers.retryNow(job)
            await waitUntil(8) { job.attempt >= 1 }
            await waitUntil(8) { if case .waiting = job.status { true } else { false } }
            lines.append(String(format: "after Retry Now (%.1f s): ", Date().timeIntervalSince(start)) + describe())
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            transfers.retryNow(job)
            await waitUntil(15) { job.status == .finished }
            lines.append("after fixing and Retry Now: \(describe()) · copied \(fm.fileExists(atPath: dest.appendingPathComponent("Pack/a.bin").path))")
            transfers.dismissFinished()
            try? fm.removeItem(at: root)
            lines.append("done")
        }
    }

    /// `-BlitLinkTest <log>`: the round trip and route measured for servers the
    /// app connects to at launch (warm-up), as the sidebar hover shows them.
    static func runLinkTestIfRequested(connections: ConnectionManager, servers: ServerStore) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitLinkTest") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(12))
            let lines = servers.browsable.map { server in
                "\(server.displayName): \(connections.state(server)) · \(connections.links[server.id]?.summary ?? "not measured")"
            }
            try? (lines + ["done"]).joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }

    /// `-BlitDiskBoundTest <log>`: the "server disk bound" hint appears for an even,
    /// slow download and not for an uneven one or a fast one.
    static func runDiskBoundTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitDiskBoundTest") else { return }
        var lines: [String] = []
        for (label, rate, rates) in [("even 25 MB/s", 25.0, [8.0, 9, 8]), ("uneven 25 MB/s", 25.0, [20.0, 4, 1]),
                                     ("even 70 MB/s", 70.0, [23.0, 24, 23])] {
            let job = TransferJob(kind: .download(ServerConfig()), sources: [], destination: URL(fileURLWithPath: "/tmp"),
                                  title: "T", destinationName: "D")
            job.status = .running
            job.history = Array(repeating: rate, count: 60)
            job.connectionRates = rates
            transfers.noteIfDiskBound(job)
            lines.append("\(label): \(job.log.last?.text ?? "no hint")")
        }
        try? (lines + ["done"]).joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
    }

    /// `-BlitBatchRenameTest <log>`: rename rules and previews, a batch with a
    /// swap (a ↔ b) undone in one step, and Copy To.
    static func runBatchRenameTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitBatchRenameTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let browser = BrowserModel.active, let undo = browser.operations.undoManager else { return lines.append("no browser/undo") }
            // Rules
            let date = ISO8601DateFormatter().date(from: "2026-09-26T10:03:04Z")!
            var replace = RenameRule(); replace.find = "."; replace.replacement = " "
            var regex = RenameRule(); regex.find = #"^(.+?)\.S(\d+)E(\d+).*$"#; regex.replacement = "$1 - s$2e$3"; regex.regularExpression = true
            var add = RenameRule(); add.mode = .add; add.addText = " [reviewed]"
            var format = RenameRule(); format.mode = .format; format.customName = "Clip "; format.startAt = 7
            for (label, rule) in [("replace", replace), ("regex", regex), ("add", add), ("format", format)] {
                lines.append("\(label): \(rule.apply(to: "Some.Show.S01E02.1080p.mkv", index: 1, date: date))")
            }
            lines.append("no real extension: \(add.apply(to: "Some.Show.S01E02", index: 0, date: date))")
            // The naming-convention presets
            let conventions = RenamePresets.conventions
            for name in ["The.Gentlemen.2019.UHD.BluRay.2160p.TrueHD.Atmos.7.1.HEVC.REMUX-FraMeSToR.mkv",
                         "Toy.Story.5.2026.UHD.BluRay.2160p.TrueHD.Atmos.7.1.DV.HEVC.REMUX-FraMeSToR.mkv",
                         "President.Curtis.S01E09.1080p.WEB.h264-EDITH.mkv",
                         "South.Park.S29E01.1080p.WEB.h264-GRACE.mkv",
                         "Blade.Runner.2049.2017.1080p.BluRay.mkv", "Movie.2019.mkv", "Show.S01E01E02.720p.mkv",
                         "Some.Show.S02.COMPLETE.1080p"] {
                let results = conventions.map { "\($0.name.prefix(6)): \(RenameRule.apply($0.steps, to: name, index: 0, date: date))" }
                lines.append("\(name)\n    \(results.joined(separator: "\n    "))")
            }
            // Previews
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-batch-rename-test")
            try? fm.removeItem(at: root)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            for (name, body) in [("a.txt", "A"), ("b.txt", "B"), ("c.txt", "C"), ("taken.txt", "T")] {
                fm.createFile(atPath: root.appendingPathComponent(name).path, contents: Data(body.utf8))
            }
            let items = (try? BrowserModel.listLocal(root, showHidden: false)) ?? []
            func item(_ n: String) -> FileItem { items.first { $0.name == n }! }
            var toTaken = RenameRule(); toTaken.find = "c"; toTaken.replacement = "taken"
            let clash = RenamePlan.rows([item("c.txt")], steps: [toTaken]) { _ in items.map(\.name) }
            lines.append("preview c → taken: \(clash[0].problem ?? "ok")")
            var same = RenameRule(); same.mode = .format; same.customName = "x"; same.format = .date
            let dupes = RenamePlan.rows([item("a.txt"), item("b.txt")], steps: [same]) { _ in items.map(\.name) }
            lines.append("preview two to one name: \(dupes.map { $0.problem ?? "ok" })")
            // Batch with a swap, then one undo
            @MainActor func state() -> String {
                ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted().map { name in
                    "\(name)=\((try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? "?")"
                }.joined(separator: " ")
            }
            let message = await browser.operations.renameMany([
                (item: .local(root.appendingPathComponent("a.txt")), name: "b.txt"),
                (item: .local(root.appendingPathComponent("b.txt")), name: "a.txt"),
                (item: .local(root.appendingPathComponent("c.txt")), name: "d.txt"),
            ])
            lines.append("after batch: \(state()) · problems: \(message ?? "none") · undo: \(undo.undoActionName)")
            undo.undo()
            try? await Task.sleep(for: .seconds(1.5))
            lines.append("after one undo: \(state())")
            // Copy To
            let target = root.appendingPathComponent("Archive")
            try? fm.createDirectory(at: target, withIntermediateDirectories: true)
            browser.send([item("taken.txt")], to: .local(target), name: "Archive", move: false)
            for _ in 0..<40 where !fm.fileExists(atPath: target.appendingPathComponent("taken.txt").path) { try? await Task.sleep(for: .milliseconds(250)) }
            try? await Task.sleep(for: .seconds(1))
            lines.append("copy to Archive: copied \(fm.fileExists(atPath: target.appendingPathComponent("taken.txt").path)), original kept \(fm.fileExists(atPath: root.appendingPathComponent("taken.txt").path))")
            lines.append("destinations: \(BrowserModel.destinations().count) offered")
            transfers.dismissFinished()
            try? fm.removeItem(at: root)
            lines.append("done")
        }
    }

    /// `-BlitRenderPathBar out.png`: the path bar with nothing selected and with
    /// two files and a folder selected (the selection count at its end).
    static func renderPathBarIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "BlitRenderPathBar") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let browser = BrowserModel.active else { return }
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("Blit Path Bar Test")
            try? fm.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
            for (name, size) in [("a.mkv", 1_200_000_000), ("b.mkv", 800_000_000), ("c.nfo", 4_000)] {
                fm.createFile(atPath: root.appendingPathComponent(name).path, contents: nil)
                if let h = FileHandle(forWritingAtPath: root.appendingPathComponent(name).path) { try? h.truncate(atOffset: UInt64(size)); try? h.close() }
            }
            browser.open(.local(root))
            for _ in 0..<20 where browser.items.count < 4 { try? await Task.sleep(for: .milliseconds(200)) }
            @MainActor func shot() -> NSImage? {
                let renderer = ImageRenderer(content: PathBar(browser: browser).frame(width: 700).background(Color(white: 0.93)))
                renderer.scale = 2
                return renderer.nsImage
            }
            let none = shot()
            browser.selection = Set(browser.items.filter { $0.name != "c.nfo" }.map(\.location))
            try? await Task.sleep(for: .milliseconds(300))
            let some = shot()
            let content = VStack(spacing: 4) {
                if let none { Image(nsImage: none) }
                if let some { Image(nsImage: some) }
            }
            let renderer = ImageRenderer(content: content)
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
            try? fm.removeItem(at: root)
        }
    }

    /// `-BlitHUDHeightTest <log>` (use with -BlitIsolatedQueue YES): the expanded
    /// HUD's fitted height across states. It should be the same in all of them.
    static func runHUDHeightTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitHUDHeightTest") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            @MainActor func job(_ kind: TransferJob.Kind) -> TransferJob {
                let j = TransferJob(kind: kind, sources: [], destination: URL(fileURLWithPath: "/tmp"), title: "SHOOT_2026-09", destinationName: "Incoming")
                j.persistent = false
                j.status = .running
                j.fileCount = 26; j.filesFinished = 7; j.totalBytes = 100; j.connections = 3; j.link = "3× · 255K×32 · EN7"
                return j
            }
            @MainActor func height(_ j: TransferJob) -> CGFloat {
                let view = NSHostingView(rootView: TransferHUD(job: j).environment(transfers).frame(width: 960))
                return view.fittingSize.height
            }
            var lines: [String] = []
            let a = job(.download(ServerConfig()))
            a.note("CONNECT · 3 CONNECTIONS")
            transfers.debugAppend([a])
            lines.append("download, 1 log line, no rates (1 job): \(height(a))")
            for i in 0..<12 { a.note(i % 2 == 0 ? "✓ SHA256 9F3A1C… VERIFIED · A001_C00\(i).MOV" : "GET A001_C00\(i).MOV → INCOMING", failure: i == 5) }
            a.connectionRates = [9, 8, 9]
            lines.append("download, full log with glyphs, 3 connections: \(height(a))")
            a.connectionRates = Array(repeating: 7, count: 8)
            a.hashed = ["a.mov": 10, "b.mov": 20, "c.mov": 30]; a.hashSizes = ["a.mov": 100, "b.mov": 100, "c.mov": 100]
            lines.append("download, 8 connections + 3 hashing: \(height(a))")
            a.connectionRates = [9, 8, 9]
            lines.append("download, 3 connections + 3 hashing: \(height(a))")
            if let png = UserDefaults.standard.string(forKey: "BlitHUDHeightPNG") {
                let renderer = ImageRenderer(content: TransferHUD(job: a).environment(transfers).frame(width: 960))
                renderer.scale = 1.5
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: png))
                }
            }
            a.failures = ["A001_C003.MOV: SHA-256 MISMATCH"]
            lines.append("download, 1 failure: \(height(a))")
            a.failures = (0..<9).map { "A001_C00\($0).MOV: SHA-256 MISMATCH · KEPT .BLITPART · A LONG REASON THAT WRAPS ONTO MORE LINES" }
            lines.append("download, 9 long failures (1 job): \(height(a))")
            let c = job(.copy)
            c.connectionRates = [50, 48]
            c.note("COPY A001_C001.MOV")
            transfers.debugAppend([c])
            lines.append("copy, 2 streams, 2 jobs queued: \(height(c))")
            let more = (0..<5).map { _ in job(.copy) }
            more.forEach { $0.status = .queued }
            transfers.debugAppend(more)
            lines.append("copy, 7 jobs queued: \(height(c))")
            transfers.debugRemove([a, c] + more)
            try? (lines + ["done"]).joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }

    /// `-BlitLicenseTest <log>` (with -BlitIsolatedQueue YES, so the trial and
    /// license live in memory): trial days, the transfer gate, offline grace,
    /// and one real call to Lemon Squeezy with a made-up key.
    static func runLicenseTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitLicenseTest") else { return }
        Task { @MainActor in
            var lines: [String] = []
            guard TransferManager.isIsolated, let memory = LicenseManager.shared.storage as? MemoryLicenseStorage else {
                try? "refusing: not isolated\n".write(toFile: logPath, atomically: true, encoding: .utf8); return
            }
            let license = LicenseManager.shared
            let now = Date()
            for days in [0.0, 3, 6.9, 7, 30] {
                lines.append("trial started \(days) days ago: \(LicenseManager.trialState(start: now.addingTimeInterval(-days * 86_400), now: now))")
            }
            @MainActor func setTrial(daysAgo: Double) {
                memory.items["trial-start"] = Data(String(now.addingTimeInterval(-daysAgo * 86_400).timeIntervalSince1970).utf8)
                memory.items["license"] = nil
            }
            // The gate: a server destination gets past the license check to the
            // "uploading isn't supported" message, so nothing is queued either way.
            let probe = BrowseLocation.remote(server: UUID(), path: Array("x".utf8))
            setTrial(daysAgo: 2)
            lines.append("day 2, enqueue: \(transfers.enqueue([.local(URL(fileURLWithPath: "/tmp"))], to: probe, destinationName: "x") ?? "queued")")
            setTrial(daysAgo: 8)
            lines.append("day 8, enqueue: \(transfers.enqueue([.local(URL(fileURLWithPath: "/tmp"))], to: probe, destinationName: "x") ?? "queued")")
            lines.append("day 8, can start: \(license.canStartTransfers) · \(license.summary)")
            // Offline grace
            for daysAgo in [3.0, 40] {
                let stored = StoredLicense(key: "ABCD-1234-EFGH-5678", instanceID: "i", email: "buyer@example.com", name: nil,
                                           lastValidated: now.addingTimeInterval(-daysAgo * 86_400))
                memory.items["license"] = try? JSONEncoder().encode(stored)
                license.refresh()
                lines.append("licensed, last checked \(Int(daysAgo)) days ago: \(license.summary) · can start \(license.canStartTransfers)")
            }
            memory.items["license"] = nil
            setTrial(daysAgo: 1)
            license.refresh()
            // Error wording
            for e in ["license_key not found.", "This license key has reached the activation limit.", "license_key is disabled."] {
                lines.append("explain \"\(e)\" → \(LicenseManager.explain(e))")
            }
            // One real request with a key that doesn't exist.
            let problem = await license.activate("BLIT-TEST-0000-0000-NOT-A-REAL-KEY", instanceName: "Blit test")
            lines.append("live API, made-up key: \(problem ?? "activated?!") · state \(license.summary)")
            try? (lines + ["done"]).joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }

    /// `-BlitRenderProductImage out.png` (with -BlitIsolatedQueue YES): a 1600×1200
    /// product image for the store: icon, name, tagline and the real HUD.
    static func renderProductImageIfRequested(transfers: TransferManager) {
        guard let path = UserDefaults.standard.string(forKey: "BlitRenderProductImage") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let job = TransferJob(kind: .download(ServerConfig()), sources: [], destination: URL(fileURLWithPath: "/tmp"),
                                  title: "SHOOT_2026-09", destinationName: "Incoming")
            job.persistent = false
            job.status = .running
            job.fileCount = 26; job.filesFinished = 17; job.filesVerified = 17
            job.totalBytes = 61_200_000_000; job.counter.add(40_900_000_000)
            job.connections = 3; job.link = "3× · 255K×32 · EN7"; job.rttMilliseconds = 148
            job.rate = 74.2; job.peakRate = 81.3; job.hashCacheHits = 5
            job.history = (0..<60).map { i in 62 + 12 * sin(Double(i) / 5) + Double(i % 7) }
            job.connectionRates = [25.1, 23.8, 25.3]
            job.hashed = ["A001_C017.MOV": 2_600_000_000]; job.hashSizes = ["A001_C017.MOV": 4_100_000_000]
            for (i, text) in ["CONNECT · 3 CONNECTIONS · 255K×32 · EN7", "RESUME A001_C015.MOV · 1.4 GB ON DISK",
                              "✓ SHA256 9F3A1C… VERIFIED · A001_C015.MOV", "DOWNLOADED A001_C016.MOV · VERIFYING",
                              "✓ SHA256 2B77E0… VERIFIED · A001_C016.MOV · SERVER CACHE", "GET A001_C018.MOV → INCOMING"].enumerated() {
                _ = i; job.note(text)
            }
            let art = ["......##......", "......##......", "......##......", "......##......",
                       "..##########..", "...########...", "....######....", ".....####.....",
                       "......##......", "..............", "..............", "##.##.##.##.::"]
            let icon = Canvas { context, size in
                let cell = size.width / 14
                for (y, row) in art.enumerated() {
                    for (x, ch) in row.enumerated() where ch != "." {
                        context.fill(Path(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell)),
                                     with: .color(ch == "#" ? HUDColor.bright : Color(white: 0.29)))
                    }
                }
            }
            .frame(width: 112, height: 96)
            let content = VStack(alignment: .leading, spacing: 34) {
                HStack(alignment: .center, spacing: 34) {
                    RoundedRectangle(cornerRadius: 34).fill(Color(white: 0.07))
                        .overlay(RoundedRectangle(cornerRadius: 34).strokeBorder(HUDColor.border, lineWidth: 1))
                        .overlay(icon)
                        .frame(width: 168, height: 168)
                    VStack(alignment: .leading, spacing: 10) {
                        Text("BLIT").font(HUDFont.label(92)).foregroundStyle(HUDColor.bright)
                        Text("Big files, moved fast, proven intact.").font(HUDFont.terminal(44)).foregroundStyle(HUDColor.bright)
                        Text("SFTP · DRIVES · NAS  —  EVERY FILE SHA-256 VERIFIED WHERE IT LANDS")
                            .font(HUDFont.label(15)).foregroundStyle(HUDColor.dim)
                    }
                }
                // Laid out at 1152 wide, drawn 1.25× (whole-pixel cells) to fill the width.
                TransferHUD(job: job).environment(transfers).frame(width: 1152)
                    .scaleEffect(1.25, anchor: .topLeading)
                    .frame(width: 1440, height: 461 * 1.25, alignment: .topLeading)
            }
            .padding(.horizontal, 80)
            .frame(width: 1600, height: 1200, alignment: .center)
            .background(HUDColor.background)
            .environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
            }
        }
    }

    static func runUndoTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitUndoTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let operations = BrowserModel.active?.operations, let undo = operations.undoManager else {
                lines.append("no operations/undo manager")
                return
            }
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-undo-test")
            try? fm.removeItem(at: root)
            try? fm.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
            let file = root.appendingPathComponent("a.txt")
            try? Data("a".utf8).write(to: file)
            func listing() -> String { ((try? fm.subpathsOfDirectory(atPath: root.path)) ?? []).sorted().joined(separator: " ") }
            func settle() async { try? await Task.sleep(for: .milliseconds(800)) }

            _ = try? await operations.rename(.local(file), to: "b.txt")
            lines.append("after rename: \(listing()) · undo: \(undo.undoActionName)")
            undo.undo(); await settle()
            lines.append("after undo:   \(listing())")

            _ = await operations.place([.local(file)], into: .local(root.appendingPathComponent("sub")), destinationName: "sub", mode: .move)
            lines.append("after move:   \(listing()) · undo: \(undo.undoActionName)")
            undo.undo(); await settle()
            lines.append("after undo:   \(listing())")

            _ = await operations.moveToTrash([.local(file)])
            lines.append("after trash:  \(listing()) · undo: \(undo.undoActionName)")
            undo.undo(); await settle()
            lines.append("after undo:   \(listing())")
            lines.append("done")
            try? fm.removeItem(at: root)
        }
    }

    /// `-BlitRenderInfo out.png`: renders Get Info for a sample verified file,
    /// and Go to Folder, for checking their look.
    static func renderInfoIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "BlitRenderInfo") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let browser = BrowserModel.active else { return }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Sample.Release.2160p.mkv")
            try? Data(repeating: 7, count: 123_456).write(to: file)
            VerifiedIndex.shared.record(TransferRecord(time: Date(), source: "user@seedbox.example:files/downloads/Sample.Release.2160p.mkv",
                                                       destination: file.path, size: 123_456,
                                                       sha256: "cdcce6b6b6e94f6f3b0f2d6f8a1c1e0b7a2e7c9d3f1a4b5c6d7e8f9a0b1c2d3e",
                                                       verification: "server-sha256", result: "ok", detail: nil))
            let item = FileItem(location: .local(file), name: file.lastPathComponent, isDirectory: false, modified: Date(),
                                size: 123_456, kind: "Matroska Video")
            for (suffix, view) in [("-info", AnyView(InfoView(item: item, browser: browser))),
                                   ("-goto", AnyView(GoToFolderView(browser: browser)))] {
                let renderer = ImageRenderer(content: view.background(Color(nsColor: .windowBackgroundColor)))
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "\(suffix).png")))
                }
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// `-BlitLogWindowTest <log>`: opens Window › Transfer Log through the menu
    /// and reports its rows against the log file.
    static func runLogWindowTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitLogWindowTest") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            var lines: [String] = []
            let windowMenu = NSApp.mainMenu?.items.first { $0.submenu?.title == "Window" }?.submenu
            let titles = windowMenu?.items.map(\.title).filter { !$0.isEmpty } ?? []
            lines.append("window menu: \(titles.joined(separator: " | "))")
            if let menu = windowMenu, let index = menu.items.firstIndex(where: { $0.title == "Transfer Log" }) {
                lines.append("shortcut: \(menu.items[index].keyEquivalentModifierMask.contains(.option) ? "⌥" : "")⌘\(menu.items[index].keyEquivalent.uppercased())")
                menu.performActionForItem(at: index)
            }
            try? await Task.sleep(for: .seconds(2))
            let logWindow = NSApp.windows.first { $0.title == "Transfer Log" }
            func tables(in view: NSView?) -> [NSTableView] {
                guard let view else { return [] }
                return (view as? NSTableView).map { [$0] } ?? view.subviews.flatMap { tables(in: $0) }
            }
            let rows = tables(in: logWindow?.contentView).first?.numberOfRows ?? -1
            let records = TransferLog.records().count
            lines.append("log window open: \(logWindow != nil) · rows \(rows) · records in file \(records)")
            lines.append("done")
            try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }

    /// `-BlitLaneTest <log>`: the copy-waits-for-download rule of the two lanes.
    static func runLaneTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitLaneTest") else { return }
        Task { @MainActor in
            var server = ServerConfig()
            server.host = "example.invalid"
            let ssd = URL(fileURLWithPath: "/Volumes/TestSSD/Downloads")
            let download = TransferJob(kind: .download(server), sources: [.remote(server.id, RemotePath("files/Pack"))],
                                       destination: ssd, title: "Pack", destinationName: "Downloads")
            download.status = .paused   // stays put: never starts
            let dependent = TransferJob(kind: .copy, sources: [.local(ssd.appendingPathComponent("Pack"))],
                                        destination: URL(fileURLWithPath: "/Volumes/Media/Movies"), title: "Pack",
                                        destinationName: "Movies")
            let unrelated = TransferJob(kind: .copy, sources: [.local(URL(fileURLWithPath: "/Volumes/TestSSD/Other"))],
                                        destination: URL(fileURLWithPath: "/Volumes/Media/Movies"), title: "Other",
                                        destinationName: "Movies")
            for job in [dependent, unrelated] { job.status = .paused }
            transfers.debugAppend([download, dependent, unrelated])
            var lines = ["lanes: download=\(download.lane) copy=\(dependent.lane)"]
            lines.append("dependent blocked while download waits: \(transfers.isBlocked(dependent))")
            lines.append("unrelated blocked: \(transfers.isBlocked(unrelated))")
            download.status = .finished
            lines.append("dependent blocked after download finished: \(transfers.isBlocked(dependent))")
            transfers.debugRemove([download, dependent, unrelated])
            lines.append("done")
            try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8)
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
