// Debug builds only: a self-test for right-click menus, since they can't be
// checked from outside the app without Accessibility access. Launch with
// `-BlitRightClickTest /path/to/log.txt`: Blit opens a small temporary folder,
// sends itself right-clicks at a few points, writes which menu opened at each
// (or none), then goes back.

#if DEBUG
import AppKit
import AVFoundation
import BlitLocal
import BlitRemote
import BlitSFTP
import SwiftUI

@MainActor
enum UITestHarness {
    /// `-BlitRenderMenuBar out.png`: every menu bar item state at 4×, on light
    /// and dark bars, each in a frame showing its width.
    static func renderMenuBarIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "BlitRenderMenuBar") else { return }
        typealias L = MenuBarIcon.Line
        let states: [(String, [NSImage])] = [
            ("idle", [MenuBarIcon.idle]),
            ("down 20%", [MenuBarIcon.image([L(up: false, verifying: false, progress: 0.2, text: MenuBarIcon.time(760))], frame: 0)]),
            ("up 88%", [MenuBarIcon.image([L(up: true, verifying: false, progress: 0.88, text: MenuBarIcon.time(68))], frame: 1)]),
            ("1h05", [MenuBarIcon.image([L(up: false, verifying: false, progress: 0.5, text: MenuBarIcon.time(3900))], frame: 2)]),
            ("percent", [MenuBarIcon.image([L(up: false, verifying: false, progress: 1, text: "100%")], frame: 0)]),
            ("verify", [MenuBarIcon.image([L(up: true, verifying: true, progress: nil, text: MenuBarIcon.time(300))], frame: nil)]),
            ("both", [MenuBarIcon.image([L(up: true, verifying: false, progress: nil, text: "1m"),
                                         L(up: false, verifying: false, progress: nil, text: "12m")], frame: 0)]),
            ("both+sha", [MenuBarIcon.image([L(up: true, verifying: true, progress: nil, text: "4m"),
                                             L(up: false, verifying: false, progress: nil, text: "1h05")], frame: 1)]),
            ("retry", [MenuBarIcon.image([L(up: false, verifying: false, progress: 0.4, text: "···")], frame: nil)]),
            ("paused", [MenuBarIcon.paused]),
            ("done", [MenuBarIcon.done]),
            ("failed", [MenuBarIcon.idle, MenuBarIcon.failureMark]),
        ]
        let bar = { (scheme: ColorScheme) in
            HStack(spacing: 10) {
                ForEach(states.indices, id: \.self) { i in
                    VStack(spacing: 2) {
                        HStack(spacing: 3) {
                            ForEach(states[i].1.indices, id: \.self) { Image(nsImage: states[i].1[$0]) }
                        }
                        .frame(height: 22)
                        .border(Color.gray.opacity(0.4), width: 0.5)
                        Text(states[i].0).font(.system(size: 7)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
            .foregroundStyle(.primary)
            .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.9))
            .environment(\.colorScheme, scheme)
        }
        let renderer = ImageRenderer(content: VStack(spacing: 0) { bar(.light); bar(.dark) })
        renderer.scale = 4
        if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

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
                ForEach(0..<3) { Image(nsImage: PixelArt.image(PixelArt.menuBarArrow(frame: $0, up: true), cell: 1.5)) }
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
            // Leave less room than the 400 MB copy needs (whatever the volume's size),
            // so it must wait for space.
            write(filler, megabytes: max(0, Int(free >> 20) - 150))
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
            // A real test-mode key (-BlitLicenseTestKey): activate, check, then free the activation.
            if let real = UserDefaults.standard.string(forKey: "BlitLicenseTestKey") {
                memory.items["license"] = nil
                let problem = await license.activate(real, instanceName: "Blit test")
                lines.append("real test key: \(problem ?? "activated") · \(license.summary) · can start \(license.canStartTransfers)")
                if var stored = license.license {
                    stored.lastValidated = .distantPast   // force the weekly check now
                    memory.items["license"] = try? JSONEncoder().encode(stored)
                    await license.revalidateIfDue()
                    lines.append("weekly check: \(license.summary)")
                }
                let freed = await license.deactivate()
                lines.append("deactivate: \(freed ?? "ok") · \(license.summary)")
            }
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

    /// `-BlitVerifyTest <log> -BlitVerifyTestDest <folder on another volume>`, with
    /// `-verifyFiles sizeOnly` (a launch argument: not saved): a copy is size-checked
    /// and labelled so; a move still verifies by SHA-256 before removing sources.
    static func runVerifyTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitVerifyTest"),
              let destPath = UserDefaults.standard.string(forKey: "BlitVerifyTestDest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-verify-test")
            try? fm.removeItem(at: root)
            let dest = URL(fileURLWithPath: destPath)
            for pack in ["Copy", "Move"] {
                let dir = root.appendingPathComponent(pack)
                try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
                for name in ["a.bin", "b.bin"] {
                    fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data((0..<(1 << 20)).map { _ in UInt8.random(in: 0...255) }))
                }
            }
            lines.append("setting: \(UserDefaults.standard.string(forKey: "verifyFiles") ?? "sha256") · default verify \(TransferJob.defaultVerify)")
            for (pack, move) in [("Copy", false), ("Move", true)] {
                if let message = transfers.enqueue([.local(root.appendingPathComponent(pack))], to: .local(dest), destinationName: "dest", move: move) {
                    lines.append("\(pack): \(message)"); continue
                }
                guard let job = transfers.transferJobs.last else { continue }
                for _ in 0..<120 where job.status != .finished && !(job.status == .failed("") ) {
                    if case .failed = job.status { break }
                    try? await Task.sleep(for: .milliseconds(250))
                }
                try? await Task.sleep(for: .seconds(1))
                let sourceLeft = fm.fileExists(atPath: root.appendingPathComponent(pack).appendingPathComponent("a.bin").path)
                lines.append("\(pack): \(job.status) · verifies \(job.verifies) · verified \(job.filesVerified) · size-checked (off) \(job.unverifiedCount) · method \(job.verificationMethod) · count \(job.countLabel) · outcomes \(job.outcomes.values.sorted()) · source kept \(sourceLeft)")
            }
            transfers.dismissFinished()
            try? fm.removeItem(at: root)
            lines.append("done")
        }
    }

    /// `-BlitHashProgressTest <log> -BlitHashProgressTestDest <folder on another
    /// volume>`: copies a 2 GB file and samples the verify progress while its
    /// SHA-256 is read back, logging each distinct percentage the HUD would show.
    static func runHashProgressTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitHashProgressTest"),
              let destPath = UserDefaults.standard.string(forKey: "BlitHashProgressTestDest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-hash-progress-test")
            try? fm.removeItem(at: root)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            let file = root.appendingPathComponent("big.bin")
            fm.createFile(atPath: file.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: file) {
                let chunk = Data((0..<(64 << 20)).map { UInt8(truncatingIfNeeded: $0 &* 2654435761) })
                for _ in 0..<32 { handle.write(chunk) }
                try? handle.close()
            }
            if let message = transfers.enqueue([.local(file)], to: .local(URL(fileURLWithPath: destPath)), destinationName: "dest", move: false) {
                lines.append("enqueue: \(message)"); lines.append("done"); return
            }
            guard let job = transfers.transferJobs.last else { return }
            var seen: [String] = []
            for _ in 0..<2400 {
                if job.status == .finished { break }
                if case .failed = job.status { break }
                if job.isVerifyingOnly {
                    let shown = job.verifyProgress.map { "\(Int(($0 * 100).rounded(.down)))%" } ?? "nil"
                    if seen.last != shown { seen.append(shown) }
                }
                try? await Task.sleep(for: .milliseconds(20))
            }
            lines.append("status \(job.status) · method \(job.verificationMethod) · verified \(job.filesVerified)")
            lines.append("verify progress seen: \(seen.joined(separator: " "))")
            transfers.dismissFinished()
            try? fm.removeItem(at: root)
            try? fm.removeItem(at: URL(fileURLWithPath: destPath).appendingPathComponent("big.bin"))
            lines.append("done")
        }
    }

    /// `-BlitRenderSettings out.png` (with -BlitIsolatedQueue YES): the Settings
    /// view hosted in a window of its own and snapshotted (the General tab),
    /// with its fitted size logged.
    static func renderSettingsIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "BlitRenderSettings") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let host = NSHostingView(rootView: SettingsView())
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
                                  styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .darkAqua)
            window.contentView = host
            window.orderFront(nil)
            try? await Task.sleep(for: .seconds(1.5))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            try? "fitted size \(size)".write(toFile: path + ".txt", atomically: true, encoding: .utf8)
            window.orderOut(nil)
        }
    }

    /// `-BlitShareTest <log>` (with -BlitIsolatedQueue YES): shares are remembered
    /// with their smb:// address, and mounting one that's already mounted goes
    /// through NetFS without UI (EEXIST) and doesn't disturb it.
    static func runShareTestIfRequested(sidebar: SidebarModel) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitShareTest") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            var lines: [String] = []
            for share in sidebar.networkShares {
                let mountPoint = share.url.standardizedFileURL.path
                let (status, address) = await ShareMounter.debugMount(mountPoint)
                let reconnect = await ShareMounter.reconnect(mountPoint)
                lines.append("\(share.name): known \(ShareMounter.isKnown(mountPoint)) · \(address) · NetFS \(status)\(status == EEXIST ? " (already mounted)" : "") · reconnect: \(reconnect ?? "ok") · still mounted \(MountInfo.of(mountPoint)?.mountPoint == mountPoint) · missingShare \(ShareMounter.missingShare(containing: mountPoint + "/x") ?? "nil")")
            }
            lines.append("missingShare for a local drive path: \(ShareMounter.missingShare(containing: "/Users/x") ?? "nil")")
            if sidebar.networkShares.isEmpty { lines.append("no network shares mounted") }
            try? (lines + ["done"]).joined(separator: "\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }

    /// `-BlitRenameFieldTest <log>` (with -BlitIsolatedQueue YES): the rename field
    /// selects the base name, scrolls to the end of a long name (snapshot at
    /// <log>.png), and Return renames; a single click on the selected file's
    /// name starts a rename (click to rename).
    static func runRenameFieldTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitRenameFieldTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let browser = BrowserModel.active, let window = BrowserModel.activeWindow else { return lines.append("no browser") }
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-rename-field-test")
            try? fm.removeItem(at: root)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            let long = "Some.Movie.Title.1999.2160p.UHD.BluRay.REMUX.DV.HDR.HEVC.DTS-HD.MA.5.1-GROUP.mkv"
            fm.createFile(atPath: root.appendingPathComponent(long).path, contents: Data("x".utf8))
            browser.open(.local(root))
            for _ in 0..<20 where browser.items.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            guard let item = browser.items.first else { return lines.append("no item") }
            // 1. The field
            browser.beginRename(item)
            try? await Task.sleep(for: .seconds(1))
            guard let editor = window.firstResponder as? NSTextView else { return lines.append("no field editor · responder \(String(describing: window.firstResponder))") }
            lines.append("selected \(NSStringFromRange(editor.selectedRange())) of \((long as NSString).length) (base name is \((long as NSString).length - 4))")
            editor.moveToEndOfLine(nil)
            try? await Task.sleep(for: .milliseconds(300))
            let caret = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
            let field = editor.delegate as? NSTextField
            let fieldRect = field.map { $0.window?.convertToScreen($0.convert($0.bounds, to: nil)) ?? .zero } ?? .zero
            lines.append("caret at end inside the field: \(fieldRect.insetBy(dx: -2, dy: -2).contains(CGPoint(x: caret.minX, y: caret.midY)))")
            if let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.cacheDisplay(in: content.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: logPath + ".png"))
            }
            editor.selectAll(nil)
            editor.insertText("Renamed.Movie.1999.mkv", replacementRange: editor.selectedRange())
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            try? await Task.sleep(for: .seconds(1.5))
            lines.append("after Return: \(((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted()) · renaming \(browser.renaming != nil)")
            // 2. Click to rename
            for _ in 0..<20 where browser.items.first?.name != "Renamed.Movie.1999.mkv" { try? await Task.sleep(for: .milliseconds(200)) }
            guard let renamed = browser.items.first, let table = firstTable(in: window.contentView) else { return lines.append("no table") }
            browser.selection = [renamed.location]
            try? await Task.sleep(for: .milliseconds(600))
            let rowRect = table.rect(ofRow: 0)
            let nameX = table.rect(ofColumn: 0).minX + 120
            let pointInWindow = table.convert(NSPoint(x: nameX, y: rowRect.midY), to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let event = NSEvent.mouseEvent(with: type, location: pointInWindow, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    NSApp.postEvent(event, atStart: false)
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.8))
            lines.append("single click on the selected name → renaming: \(browser.renaming == renamed.location)")
            browser.cancelRename()
            try? fm.removeItem(at: root)
            lines.append("done")
        }
    }

    @MainActor private static func firstTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView, table.headerView != nil { return table }
        for sub in view.subviews { if let found = firstTable(in: sub) { return found } }
        return nil
    }

    /// `-BlitConflictTest <log> -BlitConflictTestDest <folder on another volume>`
    /// (with -BlitIsolatedQueue YES): Replace / Keep Both / Skip / Stop for a copy
    /// onto an existing file across devices, Replace for a move on one drive
    /// (the old file goes to the Trash), and the toolbar search's filtering.
    static func runConflictTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitConflictTest"),
              let destPath = UserDefaults.standard.string(forKey: "BlitConflictTestDest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let browser = BrowserModel.active else { return lines.append("no browser") }
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-conflict-test")
            try? fm.removeItem(at: root)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("movie.mkv")
            fm.createFile(atPath: source.path, contents: Data(repeating: 1, count: 2000))
            let dest = URL(fileURLWithPath: destPath)
            @MainActor func reset() {
                for name in (try? fm.contentsOfDirectory(atPath: dest.path)) ?? [] { try? fm.removeItem(at: dest.appendingPathComponent(name)) }
                fm.createFile(atPath: dest.appendingPathComponent("movie.mkv").path, contents: Data(repeating: 9, count: 1000))
            }
            @MainActor func state() -> String {
                ((try? fm.contentsOfDirectory(atPath: dest.path)) ?? []).sorted().map { name in
                    let size = (try? fm.attributesOfItem(atPath: dest.appendingPathComponent(name).path)[.size] as? NSNumber)?.intValue ?? -1
                    return "\(name)=\(size)"
                }.joined(separator: " ")
            }
            for (label, answer) in [("Replace", ConflictPrompt.Choice.replace), ("Keep Both", .keepBoth), ("Skip", .skip), ("Stop", .stop)] {
                reset()
                ConflictPrompt.testAnswer = answer
                ConflictPrompt.lastAsked = nil
                let message = await browser.operations.place([.local(source)], into: .local(dest), destinationName: "dest", mode: .copy)
                for _ in 0..<60 where transfers.transferJobs.contains(where: { $0.isActive || $0.status == .queued }) {
                    try? await Task.sleep(for: .milliseconds(250))
                }
                try? await Task.sleep(for: .milliseconds(500))
                lines.append("copy onto existing, \(label): asked \(ConflictPrompt.lastAsked.map { "\($0.count), move \($0.move)" } ?? "no") · message \(message.map { "“\($0)”" } ?? "none") · dest \(state())")
                transfers.dismissFinished()
            }
            // Same drive: move onto an existing file, Replace.
            let other = root.appendingPathComponent("sub")
            try? fm.createDirectory(at: other, withIntermediateDirectories: true)
            fm.createFile(atPath: other.appendingPathComponent("movie.mkv").path, contents: Data(repeating: 7, count: 500))
            ConflictPrompt.testAnswer = .replace
            _ = await browser.operations.place([.local(source)], into: .local(other), destinationName: "sub", mode: .move)
            let movedSize = (try? fm.attributesOfItem(atPath: other.appendingPathComponent("movie.mkv").path)[.size] as? NSNumber)?.intValue ?? -1
            lines.append("same-drive move, Replace: asked move \(ConflictPrompt.lastAsked?.move ?? false) · sub/movie.mkv is \(movedSize) bytes (2000 = the moved one) · source gone \(!fm.fileExists(atPath: source.path))")
            ConflictPrompt.testAnswer = nil
            // Search
            try? fm.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
            fm.createFile(atPath: root.appendingPathComponent("Folder/Nested Match.txt").path, contents: nil)
            fm.createFile(atPath: root.appendingPathComponent("Top Match.txt").path, contents: nil)
            fm.createFile(atPath: root.appendingPathComponent("Other.txt").path, contents: nil)
            browser.open(.local(root))
            for _ in 0..<20 where browser.items.count < 4 { try? await Task.sleep(for: .milliseconds(200)) }
            if let folder = browser.items.first(where: { $0.name == "Folder" }) { browser.toggleExpanded(folder) }
            try? await Task.sleep(for: .seconds(1))
            browser.searchText = "match"
            lines.append("search “match”: \(browser.rows.map(\.name))")
            browser.searchText = "zzz"
            lines.append("search “zzz”: \(browser.rows.map(\.name))")
            browser.searchText = "MATCH"
            lines.append("search is case-insensitive: \(browser.rows.count)")
            browser.open(.local(dest))
            try? await Task.sleep(for: .milliseconds(500))
            lines.append("search cleared after navigating: “\(browser.searchText)”")
            try? fm.removeItem(at: root)
            lines.append("done")
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

    /// `-BlitMenuBarTest <log>`: a download and a copy to a share running at
    /// once (simulated): lane order, the featured job, time left, the queue
    /// ETA per lane, and renders of the menu bar item and panel beside the log.
    static func runMenuBarTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitMenuBarTest") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            VolumeKinds.networkRoots.insert("/Volumes/TestShare")
            var server = ServerConfig()
            server.host = "example.invalid"
            let download = TransferJob(kind: .download(server), sources: [.remote(server.id, RemotePath("files/South.Park.S29E01.mkv"))],
                                       destination: URL(fileURLWithPath: "/Volumes/TestSSD/Downloads"),
                                       title: "South.Park.S29E01.mkv", destinationName: "Downloads")
            download.totalBytes = 10_000_000_000
            download.resumedBytes = 2_000_000_000
            download.history = Array(repeating: 60, count: 15)   // 60 MB/s: 8 GB in ~2 min 13 s
            download.fileCount = 3
            download.verifying = ["Extras.mkv": Date()]
            download.hashSizes = ["Extras.mkv": 1_000_000_000]
            download.hashed = ["Extras.mkv": 420_000_000]
            download.startedAt = Date().addingTimeInterval(-600)
            let copy = TransferJob(kind: .copy, sources: [.local(URL(fileURLWithPath: "/Volumes/TestSSD/Go 1999.mkv"))],
                                   destination: URL(fileURLWithPath: "/Volumes/TestShare/Movies"), title: "Go 1999.mkv",
                                   destinationName: "Movies")
            copy.totalBytes = 70_000_000_000
            copy.resumedBytes = 62_000_000_000
            copy.history = Array(repeating: 117, count: 15)   // 117 MB/s: 8 GB in ~68 s
            copy.fileCount = 1
            copy.startedAt = Date().addingTimeInterval(-60)
            let queued = TransferJob(kind: .copy, sources: [.local(URL(fileURLWithPath: "/Volumes/TestSSD/Next.mkv"))],
                                     destination: URL(fileURLWithPath: "/Volumes/TestShare/Movies"), title: "Next.mkv",
                                     destinationName: "Movies")
            queued.totalBytes = 30_000_000_000
            queued.status = .paused
            download.status = .running
            copy.status = .running
            transfers.debugAppend([download, copy, queued])
            queued.status = .queued
            var lines: [String] = []
            lines.append("active order: \(transfers.activeTransfers.map(\.title))")
            lines.append("outgoing: download \(download.isOutgoing) · copy \(copy.isOutgoing)")
            lines.append("featured (longest running): \(transfers.featured?.title ?? "none")")
            lines.append("seconds left: download \(download.secondsLeft ?? -1) · copy \(copy.secondsLeft ?? -1)")
            lines.append("menu bar text: download \(download.secondsLeft.map(MenuBarIcon.time) ?? "--") · copy \(copy.secondsLeft.map(MenuBarIcon.time) ?? "--")")
            let totals = transfers.queueTotals
            lines.append("queue: \(totals.queued) queued · \(totals.bytesLeft / 1_000_000_000) GB left · eta \(totals.eta ?? -1) s (copy lane 38 GB at 117 MB/s ≈ 324 s)")
            lines.append("time format: \([30, 59, 60, 754, 3599, 3600, 3900, 35_999, 36_000, 400_000].map(MenuBarIcon.time))")
            let render = { (view: AnyView, suffix: String, scale: CGFloat) in
                let renderer = ImageRenderer(content: view.environment(transfers))
                renderer.scale = scale
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: logPath.replacingOccurrences(of: ".log", with: "-\(suffix).png")))
                }
            }
            render(AnyView(MenuBarLabel().padding(4).background(Color(white: 0.9))), "label", 4)
            render(AnyView(MenuBarPanel().background(Color(white: 0.2)).environment(\.colorScheme, .dark)), "panel", 2)
            copy.status = .finished
            lines.append("featured after the copy finished: \(transfers.featured?.title ?? "none")")
            transfers.debugRemove([download, copy, queued])
            VolumeKinds.networkRoots.remove("/Volumes/TestShare")
            lines.append("done")
            try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }

    /// `-BlitNotificationTextTest <log>`: the notification for each kind of
    /// outcome, from simulated jobs (nothing is posted).
    static func runNotificationTextTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitNotificationTextTest") else { return }
        VolumeKinds.networkRoots.insert("/Volumes/TestShare")
        var server = ServerConfig()
        server.host = "example.invalid"
        let now = Date()
        func job(_ kind: TransferJob.Kind, _ title: String, to dest: String, _ name: String, files: Int, bytes: Int64,
                 minutes: Double, setup: (TransferJob) -> Void = { _ in }) -> TransferJob {
            let source: BrowseLocation = if case .download = kind { .remote(server.id, RemotePath("files/\(title)")) }
                                         else { .local(URL(fileURLWithPath: "/Volumes/TestSSD/\(title)")) }
            let j = TransferJob(kind: kind, sources: [source], destination: URL(fileURLWithPath: dest), title: title, destinationName: name)
            j.fileCount = files
            j.totalBytes = bytes
            j.filesFinished = files
            j.filesVerified = files
            j.counter.add(Int(bytes))
            j.startedAt = now.addingTimeInterval(-minutes * 60)
            j.status = .finished
            setup(j)
            return j
        }
        let cases: [(String, TransferJob)] = [
            ("download", job(.download(server), "Sexy.Beast.2000.2160p.UHD.Bluray.Remux.DV.HDR.HEVC.DTS-HD.mkv", to: "/Volumes/TestSSD/Downloads",
                             "Downloads", files: 1, bytes: 63_100_000_000, minutes: 9)),
            ("nas copy", job(.copy, "Go 1999.mkv", to: "/Volumes/TestShare/Movies", "Movies", files: 1, bytes: 71_600_000_000, minutes: 11) {
                $0.nasVerified = true }),
            ("move", job(.copy, "Pack", to: "/Volumes/TestShare/Movies", "Movies", files: 12, bytes: 210_000_000_000, minutes: 31) {
                $0.nasVerified = true; $0.deleteSources = true }),
            ("clone", job(.copy, "Pack", to: "/Volumes/TestSSD/Archive", "Archive", files: 2, bytes: 2_100_000, minutes: 0) {
                $0.filesVerified = 0; $0.outcomes = ["a.bin": "cloned", "b.bin": "cloned"] }),
            ("present", job(.copy, "Go 1999.mkv", to: "/Volumes/TestShare/Movies", "Movies", files: 1, bytes: 71_600_000_000, minutes: 0) {
                $0.filesAlreadyPresent = 1; $0.filesVerified = 0 }),
            ("verify off", job(.copy, "Pack", to: "/Volumes/TestSSD/Archive", "Archive", files: 3, bytes: 9_000_000_000, minutes: 2) {
                $0.filesVerified = 0; $0.unverifiedCount = 3 }),
            ("size only", job(.download(server), "Pack", to: "/Volumes/TestSSD/Downloads", "Downloads", files: 12, bytes: 40_000_000_000, minutes: 8) {
                $0.sizeOnlyCount = 3; $0.filesVerified = 9 }),
            ("failure", job(.copy, "Pack", to: "/Volumes/TestShare/Movies", "Movies", files: 12, bytes: 40_000_000_000, minutes: 8) {
                $0.status = .failed("2 failed")
                $0.failures = ["Extras.mkv: SHA-256 mismatch: source \(String(repeating: "a", count: 64)), NAS \(String(repeating: "b", count: 64))",
                               "Sample.mkv: permission denied"] }),
        ]
        var lines: [String] = []
        for (label, j) in cases {
            guard let c = TransferNotifications.content(for: j, eachTransfer: true, now: now) else { lines.append("\(label): none"); continue }
            lines.append("[\(label)] \(c.title) | \(c.subtitle) | \(c.body) | \(c.categoryIdentifier)\(c.sound == nil ? "" : " · sound")")
        }
        lines.append("[each off, clean] \(TransferNotifications.content(for: cases[0].1, eachTransfer: false, now: now) == nil ? "none" : "posted")")
        let batch = TransferNotifications.batchContent(jobs: 4, bytes: 210_000_000_000, failed: 0, sizeOnly: 0, unverified: 0, elapsed: 4320)
        lines.append("[batch] \(batch.title) | \(batch.subtitle) | \(batch.body)")
        VolumeKinds.networkRoots.remove("/Volumes/TestShare")
        lines.append("done")
        try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8)
    }

    /// `-BlitTrashTest <log> -BlitTrashTestDest <mount of a scratch disk image>`:
    /// fills the image, moves the filler to its Trash (the space stays used),
    /// then queues a copy that has to wait for space. Checks the strip's offer,
    /// that Cancel erases nothing, and that confirming empties that drive's
    /// Trash only and lets the copy finish.
    static func runTrashTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitTrashTest"),
              let mount = UserDefaults.standard.string(forKey: "BlitTrashTestDest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let fm = FileManager.default
            let volume = URL(fileURLWithPath: mount)
            func write(_ url: URL, megabytes: Int) {
                fm.createFile(atPath: url.path, contents: nil)
                guard let handle = try? FileHandle(forWritingTo: url) else { return }
                let chunk = Data((0..<(1 << 20)).map { _ in UInt8.random(in: 0...255) })
                for _ in 0..<megabytes { handle.write(chunk) }
                try? handle.close()
            }
            lines.append("startup disk has its own drive trash: \(TrashService.volumeTrash(containing: fm.temporaryDirectory) != nil)")
            guard let trash = TrashService.volumeTrash(containing: volume) else { lines.append("no trash for the image"); lines.append("done"); return }
            lines.append("image trash: …/\(trash.pathComponents.suffix(2).joined(separator: "/"))")
            let src = fm.temporaryDirectory.appendingPathComponent("blit-trash-src")
            try? fm.removeItem(at: src)
            try? fm.createDirectory(at: src, withIntermediateDirectories: true)
            write(src.appendingPathComponent("big.bin"), megabytes: 400)
            let filler = volume.appendingPathComponent("filler.bin")
            let free = TransferManager.freeSpace(at: volume) ?? 0
            write(filler, megabytes: max(0, Int(free >> 20) - 150))
            try? fm.trashItem(at: filler, resultingItemURL: nil)
            let before = await TrashService.contents(of: trash)
            lines.append("trashed filler: \(before.items) item, \(before.bytes >> 20) MB · free \(TransferManager.freeSpace(at: volume).map { $0 >> 20 } ?? 0) MB")
            let dest = volume.appendingPathComponent("dest")
            try? fm.createDirectory(at: dest, withIntermediateDirectories: true)
            _ = transfers.enqueue([.local(src.appendingPathComponent("big.bin"))], to: .local(dest), destinationName: "dest")
            guard let job = transfers.transferJobs.last else { return }
            for _ in 0..<300 {
                if case .waitingForSpace = job.status, job.destinationTrashBytes > 0 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            lines.append("waiting: \(job.status) · offer \(job.destinationTrashBytes >> 20) MB")
            TrashService.testAnswer = false
            lines.append("cancel: \(await transfers.emptyTrash(onDriveContaining: dest))")
            lines.append("after Cancel: \(await TrashService.contents(of: trash).items) item(s) still in the trash")
            TrashService.testAnswer = true
            lines.append("confirm: \(await transfers.emptyTrash(onDriveContaining: dest))")
            let after = await TrashService.contents(of: trash)
            lines.append("after Empty Trash: \(after.items) item(s) · free \(TransferManager.freeSpace(at: volume).map { $0 >> 20 } ?? 0) MB")
            for _ in 0..<400 where job.status != .finished {
                if case .failed = job.status { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            lines.append("copy: \(job.status) · verified \(job.filesVerified)")
            lines.append("empty again: \(await transfers.emptyTrash(onDriveContaining: dest))")
            TrashService.testAnswer = nil
            transfers.dismissFinished()
            try? fm.removeItem(at: src)
            lines.append("done")
        }
    }

    /// `-BlitOpenWithTest <log>`: the Open With apps for sample files (listed
    /// only; nothing is opened).
    static func runOpenWithTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitOpenWithTest") else { return }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("blit-openwith-test")
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = ["movie.mkv", "notes.txt", "photo.png", "clip.mp4"]
        for name in names { fm.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data("x".utf8)) }
        let url = { (name: String) in dir.appendingPathComponent(name) }
        var lines: [String] = []
        for set in [["movie.mkv"], ["notes.txt"], ["photo.png"], ["clip.mp4"], ["photo.png", "notes.txt"], ["movie.mkv", "clip.mp4"]] {
            let apps = OpenWith.apps(for: set.map(url))
            lines.append("\(set.joined(separator: " + ")): default \(apps.primary?.name ?? "none") · \(apps.others.count) others: \(apps.others.prefix(6).map(\.name).joined(separator: ", "))")
        }
        let folder = OpenWith.apps(for: [dir])
        lines.append("folder: default \(folder.primary?.name ?? "none") · \(folder.others.count) others")
        try? fm.removeItem(at: dir)
        lines.append("done")
        try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8)
    }

    /// `-BlitMediaExtensionTest <log> -BlitMediaExtensionTestDir <folder>`: with
    /// Blit's opt-in to Media Extensions, whether AVFoundation (what Quick Look
    /// plays with) can play each sample here.
    static func runMediaExtensionTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitMediaExtensionTest"),
              let dir = UserDefaults.standard.string(forKey: "BlitMediaExtensionTestDir") else { return }
        Task { @MainActor in
            var lines: [String] = []
            let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).sorted().filter { !$0.hasSuffix(".heic") }
            for name in files {
                let asset = AVURLAsset(url: URL(fileURLWithPath: dir).appendingPathComponent(name))
                let playable = (try? await asset.load(.isPlayable)) ?? false
                let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? -1
                lines.append("\(name): playable \(playable) · \(String(format: "%.2f", duration)) s")
            }
            lines.append("done")
            try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }

    /// `-BlitDropTest <log>`: real drags within a file list, driven from outside
    /// (a trusted script posts the mouse events; this copy can't). Writes each
    /// drag's screen points to <log>.points, snapshots the window when the
    /// script says it's hovering (<log>.hover-N), and logs where files landed.
    /// The last drop a file list handled (for the drop test).
    static var lastDrop = ""
    static var dropTrail: [String] = []

    static func runDropTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitDropTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let browser = BrowserModel.active, let window = BrowserModel.activeWindow else { return lines.append("no browser") }
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-drop-test")
            try? fm.removeItem(at: root)
            for folder in ["Target", "Other"] { try? fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true) }
            for file in ["a.bin", "b.bin", "c.bin"] { fm.createFile(atPath: root.appendingPathComponent(file).path, contents: Data("x".utf8)) }
            browser.open(.local(root))
            for _ in 0..<30 where browser.rows.count < 5 { try? await Task.sleep(for: .milliseconds(200)) }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.setFrame(NSRect(x: 120, y: 120, width: 1100, height: 700), display: true)
            try? await Task.sleep(for: .seconds(1))
            guard let table = firstTable(in: window.contentView) else { return lines.append("no table") }
            @MainActor func point(_ name: String) -> CGPoint? {
                guard let row = browser.rows.firstIndex(where: { $0.name == name }) else { return nil }
                let rect = table.rect(ofRow: row)
                let inWindow = table.convert(NSPoint(x: rect.minX + 90, y: rect.midY), to: nil)
                let screen = window.convertPoint(toScreen: inWindow)
                // CGEvent coordinates: origin at the top left of the main screen.
                return CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
            }
            lines.append("rows: \(browser.rows.map(\.name))")
            // Drag 1: a.bin onto Target. Drag 2: b.bin and c.bin (selected) onto
            // Other. Each drag's points are measured just before it (rows re-sort).
            let plan: [(from: String, to: String, select: [String], expect: [String])] = [
                ("a.bin", "Target", [], ["Target/a.bin"]),
                ("b.bin", "Other", ["b.bin", "c.bin"], ["Other/b.bin", "Other/c.bin"]),
            ]
            for (index, step) in plan.enumerated() {
                if !step.select.isEmpty {
                    browser.selection = Set(browser.rows.filter { step.select.contains($0.name) }.map(\.id))
                    try? await Task.sleep(for: .milliseconds(500))
                }
                guard let from = point(step.from), let to = point(step.to) else { lines.append("rows not found"); break }
                UITestHarness.lastDrop = ""
                UITestHarness.dropTrail = []
                try? JSONSerialization.data(withJSONObject: [from.x, from.y, to.x, to.y])
                    .write(to: URL(fileURLWithPath: logPath + ".points-\(index)"))
                let hover = logPath + ".hover-\(index)"
                for _ in 0..<150 where !fm.fileExists(atPath: hover) { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(300))
                if let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: logPath + "-hover-\(index).png"))
                }
                var landed = false
                for _ in 0..<50 {
                    landed = step.expect.allSatisfy { fm.fileExists(atPath: root.appendingPathComponent($0).path) }
                    if landed { break }
                    try? await Task.sleep(for: .milliseconds(200))
                }
                try? await Task.sleep(for: .seconds(2))
                if let content = window.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: logPath + "-after-\(index).png"))
                }
                lines.append("drag \(index + 1): \(step.expect.joined(separator: ", ")) landed \(landed) · drop: \(UITestHarness.lastDrop.isEmpty ? "none" : UITestHarness.lastDrop) · trail \(UITestHarness.dropTrail.reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }) · top level \(((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).sorted())")
                try? await Task.sleep(for: .seconds(1))
            }
            try? fm.removeItem(at: root)
            lines.append("done")
        }
    }

    /// `-BlitSidebarDropTest <log>`: real drags from the file list to the
    /// sidebar (driven from outside, like DropTest), with the test copy's own
    /// in-memory Favorites on temporary folders. Drag 1 ends between two
    /// favorites (the insert line), drag 2 on a favorite. Logs whether the main
    /// thread stalled, what Favorites holds, and where the file went.
    static func runSidebarDropTestIfRequested(sidebar: SidebarModel) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitSidebarDropTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        // Main-thread heartbeat: the longest gap shows a freeze.
        var lastBeat = Date(), longest: TimeInterval = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                longest = max(longest, Date().timeIntervalSince(lastBeat))
                lastBeat = Date()
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard let browser = BrowserModel.active, let window = BrowserModel.activeWindow else { return lines.append("no browser") }
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-sidebar-drop-test")
            try? fm.removeItem(at: root)
            let list = root.appendingPathComponent("List"), favA = root.appendingPathComponent("FavA"), favB = root.appendingPathComponent("FavB")
            for folder in [list, favA, favB] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
            for file in ["x.mkv", "y.mkv"] { fm.createFile(atPath: list.appendingPathComponent(file).path, contents: Data("x".utf8)) }
            try? fm.createDirectory(at: list.appendingPathComponent("Folder1"), withIntermediateDirectories: true)
            sidebar.addFavorite(.local(favA))
            sidebar.addFavorite(.local(favB))
            browser.open(.local(list))
            for _ in 0..<30 where browser.rows.count < 3 { try? await Task.sleep(for: .milliseconds(200)) }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.setFrame(NSRect(x: 120, y: 120, width: 1100, height: 700), display: true)
            try? await Task.sleep(for: .seconds(1))
            guard let table = firstTable(in: window.contentView), let outline = firstOutline(in: window.contentView) else {
                return lines.append("no table or sidebar")
            }
            try? String(window.windowNumber).write(toFile: logPath + ".wid", atomically: true, encoding: .utf8)
            @MainActor func screen(_ view: NSView, _ p: NSPoint) -> [Double] {
                let s = window.convertPoint(toScreen: view.convert(p, to: nil))
                return [s.x, (NSScreen.screens.first?.frame.height ?? 0) - s.y]
            }
            @MainActor func listPoint(_ name: String) -> [Double]? {
                guard let row = browser.rows.firstIndex(where: { $0.name == name }) else { return nil }
                let r = table.rect(ofRow: row)
                return screen(table, NSPoint(x: r.minX + 90, y: r.midY))
            }
            // Sidebar rows: 0 is the Favorites header, then one per favorite.
            @MainActor func favoriteRect(_ name: String) -> NSRect? {
                guard let i = sidebar.favorites.firstIndex(where: { $0.location.lastComponent == name }) else { return nil }
                return outline.rect(ofRow: i + 1)
            }
            @MainActor func betweenAB() -> [Double]? {
                guard let a = favoriteRect("FavA"), let b = sidebar.favorites.firstIndex(where: { $0.location.lastComponent == "FavA" })
                    .map({ outline.rect(ofRow: $0 + 2) }) else { return nil }
                return screen(outline, NSPoint(x: a.midX, y: (a.maxY + b.minY) / 2))
            }
            @MainActor func middle(_ name: String) -> [Double]? {
                favoriteRect(name).map { screen(outline, NSPoint(x: $0.midX, y: $0.midY)) }
            }
            let plan: [(label: String, from: String, to: () -> [Double]?)] = [
                ("file between favorites", "x.mkv", { betweenAB() }),
                ("folder between favorites", "Folder1", { betweenAB() }),
                ("file onto FavB", "y.mkv", { middle("FavB") }),
            ]
            lines.append("sidebar rows \(outline.numberOfRows) · list \(browser.rows.map(\.name))")
            for (index, step) in plan.enumerated() {
                longest = 0
                UITestHarness.dropTrail = []
                for _ in 0..<20 where listPoint(step.from) == nil { try? await Task.sleep(for: .milliseconds(200)) }
                guard let from = listPoint(step.from), let to = step.to() else { lines.append("\(step.label): points not found"); break }
                try? JSONSerialization.data(withJSONObject: from + to).write(to: URL(fileURLWithPath: logPath + ".points-\(index)"))
                let hover = logPath + ".hover-\(index)"
                for _ in 0..<150 where !fm.fileExists(atPath: hover) { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(4))
                let favorites = sidebar.favorites.map { $0.location.lastComponent }
                let places = [("List", list), ("FavA", favA), ("FavB", favB)].compactMap { name, folder in
                    ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).isEmpty ? nil : "\(name): \(((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted())"
                }
                lines.append("   trail \(UITestHarness.dropTrail)")
                lines.append("drag \(index + 1) (\(step.label)): stall \(String(format: "%.1f", longest)) s · favorites \(favorites) · \(places.joined(separator: " · "))")
            }
            try? fm.removeItem(at: root)
            lines.append("done")
        }
    }

    @MainActor private static func firstOutline(in view: NSView?) -> NSOutlineView? {
        guard let view else { return nil }
        if let outline = view as? NSOutlineView, outline.headerView == nil { return outline }   // the sidebar, not a file list
        for sub in view.subviews { if let found = firstOutline(in: sub) { return found } }
        return nil
    }

    /// `-BlitAutoCollapseTest <log> -BlitAutoCollapseTestDest <folder on another
    /// volume>`: the full HUD collapses to the strip 2 s after a clean, verified
    /// queue finishes, and stays open when a transfer fails.
    static func runAutoCollapseTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitAutoCollapseTest"),
              let destPath = UserDefaults.standard.string(forKey: "BlitAutoCollapseTestDest") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            var lines: [String] = []
            let fm = FileManager.default
            let src = fm.temporaryDirectory.appendingPathComponent("blit-autocollapse-src")
            try? fm.removeItem(at: src)
            try? fm.createDirectory(at: src, withIntermediateDirectories: true)
            fm.createFile(atPath: src.appendingPathComponent("ok.bin").path, contents: Data((0..<(1 << 20)).map { _ in UInt8.random(in: 0...255) }))
            let dest = URL(fileURLWithPath: destPath)
            // 1. A clean copy (verified by read-back on the other volume).
            _ = transfers.enqueue([.local(src.appendingPathComponent("ok.bin"))], to: .local(dest), destinationName: "dest")
            transfers.isExpanded = true
            guard let job = transfers.transferJobs.last else { return }
            for _ in 0..<100 where job.status != .finished { try? await Task.sleep(for: .milliseconds(100)) }
            lines.append("clean copy: \(job.status) · verified \(job.filesVerified) · HUD expanded right after \(transfers.isExpanded)")
            try? await Task.sleep(for: .seconds(3))
            lines.append("3 s later: HUD expanded \(transfers.isExpanded)")
            // 2. A failing copy (the source vanishes): the HUD stays open.
            transfers.dismissFinished()
            let missing = src.appendingPathComponent("gone.bin")
            fm.createFile(atPath: missing.path, contents: Data("x".utf8))
            _ = transfers.enqueue([.local(missing)], to: .local(dest.appendingPathComponent("sub-that-is-a-file")), destinationName: "bad")
            try? "x".write(to: dest.appendingPathComponent("sub-that-is-a-file"), atomically: true, encoding: .utf8)
            transfers.isExpanded = true
            if let bad = transfers.transferJobs.last {
                for _ in 0..<200 where bad.isActive || bad.status == .queued { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(3))
                lines.append("failing copy: \(bad.status) · failures \(bad.failures.count) · HUD expanded 3 s later \(transfers.isExpanded)")
            }
            transfers.dismissFinished()
            try? fm.removeItem(at: src)
            try? fm.removeItem(at: dest.appendingPathComponent("ok.bin"))
            try? fm.removeItem(at: dest.appendingPathComponent("sub-that-is-a-file"))
            lines.append("done")
            try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }

    /// `-BlitDragOutTest <log>`: a real drag of a file out of the list, released
    /// over the menu bar (no target there, so it's cancelled and nothing is
    /// created). Logs the longest main-thread stall during and after it.
    static func runDragOutTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitDragOutTest") else { return }
        var lastBeat = Date(), longest: TimeInterval = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                longest = max(longest, Date().timeIntervalSince(lastBeat))
                lastBeat = Date()
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            var lines: [String] = []
            guard let browser = BrowserModel.active, let window = BrowserModel.activeWindow else { return }
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-drag-out-test")
            try? fm.removeItem(at: root)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            fm.createFile(atPath: root.appendingPathComponent("out.bin").path, contents: Data("x".utf8))
            browser.open(.local(root))
            for _ in 0..<30 where browser.rows.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.setFrame(NSRect(x: 120, y: 120, width: 1100, height: 700), display: true)
            try? await Task.sleep(for: .seconds(1))
            guard let table = firstTable(in: window.contentView) else { return }
            let rect = table.rect(ofRow: 0)
            let start = window.convertPoint(toScreen: table.convert(NSPoint(x: rect.minX + 90, y: rect.midY), to: nil))
            let height = NSScreen.screens.first?.frame.height ?? 0
            // End over the menu bar, left of the centre: nothing takes a drop there.
            var end = [Double((NSScreen.screens.first?.frame.width ?? 1000) * 0.4), 4]
            // -BlitDragOutEnd "x,y": drop there instead (e.g. a Finder window the test opened).
            if let custom = UserDefaults.standard.string(forKey: "BlitDragOutEnd")?.split(separator: ",").compactMap({ Double($0) }),
               custom.count == 2 { end = custom }
            longest = 0
            try? JSONSerialization.data(withJSONObject: [start.x, height - start.y] + end)
                .write(to: URL(fileURLWithPath: logPath + ".points-0"))
            for _ in 0..<150 where !fm.fileExists(atPath: logPath + ".hover-0") { try? await Task.sleep(for: .milliseconds(100)) }
            let during = longest
            lines.append("drag types: \((NSPasteboard(name: .drag).types ?? []).map(\.rawValue))")
            for item in NSPasteboard(name: .drag).pasteboardItems ?? [] { lines.append("  item: \(item.types.map(\.rawValue))") }
            try? await Task.sleep(for: .seconds(5))
            lines.append("stall while dragging out \(String(format: "%.1f", during)) s · worst including after release \(String(format: "%.1f", longest)) s")
            lines.append("file still in place \(fm.fileExists(atPath: root.appendingPathComponent("out.bin").path))")
            try? fm.removeItem(at: root)
            lines.append("done")
            try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }

    /// `-BlitTwoPaneTest <log>`: two panes on temporary folders, driven by real
    /// key presses from scripts/ui-keys.swift: F5 copies the selection to the
    /// other pane, F6 moves it, ⌘U swaps the panes; View › Columns hides Size in
    /// both lists.
    static func runTwoPaneTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitTwoPaneTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-two-pane-test")
            try? fm.removeItem(at: root)
            let left = root.appendingPathComponent("Left"), right = root.appendingPathComponent("Right")
            for folder in [left, right] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
            for file in ["copy-me.bin", "move-me.bin"] { fm.createFile(atPath: left.appendingPathComponent(file).path, contents: Data("x".utf8)) }
            guard let first = BrowserModel.active, let window = BrowserModel.activeWindow else { return lines.append("no browser") }
            guard let second = BrowserModel.oppositePane?(first) else { return lines.append("no second pane (showSecondPane off?)") }
            first.open(.local(left))
            second.open(.local(right))
            for _ in 0..<30 where first.rows.count < 2 { try? await Task.sleep(for: .milliseconds(200)) }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.setFrame(NSRect(x: 120, y: 120, width: 1200, height: 700), display: true)
            try? await Task.sleep(for: .seconds(1))
            // The helper clicks empty space in the left list (brings this copy
            // forward, and makes the left pane the active one) before any key.
            var tables: [NSTableView] = []
            func collect(_ view: NSView) {
                if let table = view as? NSTableView, table.headerView != nil { tables.append(table) }
                view.subviews.forEach(collect)
            }
            if let content = window.contentView { collect(content) }
            guard let leftTable = tables.min(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }) else {
                return lines.append("no tables")
            }
            let below = leftTable.rect(ofRow: max(0, leftTable.numberOfRows - 1))
            let seen = leftTable.visibleRect
            let spot = window.convertPoint(toScreen: leftTable.convert(NSPoint(x: seen.midX, y: below.maxY + 60), to: nil))
            try? JSONSerialization.data(withJSONObject: [spot.x, (NSScreen.screens.first?.frame.height ?? 0) - spot.y])
                .write(to: URL(fileURLWithPath: logPath + ".click"))
            for _ in 0..<100 where !fm.fileExists(atPath: logPath + ".clicked") { try? await Task.sleep(for: .milliseconds(100)) }
            BrowserModel.onInteraction?(first)   // the left pane is the active one
            try? await Task.sleep(for: .milliseconds(500))
            lines.append("frontmost is this test copy: \(NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier) · frontmost \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?") · click at \(Int(spot.x)),\(Int(spot.y)) · window \(window.frame) · window on screen \(window.isOnActiveSpace && window.isVisible) · key \(window.isKeyWindow)")
            func contents(_ url: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }
            // A real click on a row selects it (the menus follow real selections).
            @MainActor func rowPoint(_ name: String) -> [Int] {
                guard let row = first.rows.firstIndex(where: { $0.name == name }) else { return [] }
                let r = leftTable.rect(ofRow: row)
                // On the date, not the name: a click on a selected name starts a rename.
                let seen = leftTable.visibleRect   // the list scrolls sideways in a narrow pane
                let p = window.convertPoint(toScreen: leftTable.convert(NSPoint(x: seen.minX + seen.width * 0.8, y: r.midY), to: nil))
                return [Int(p.x), Int((NSScreen.screens.first?.frame.height ?? 0) - p.y)]
            }
            @MainActor func press(_ index: Int, _ key: Int, command: Bool = false, clicking name: String? = nil) async {
                var click: [Int] = []
                if let name { click = rowPoint(name) }
                lines.append("step \(index): click \(click) · rows \(first.rows.map(\.name)) · table rows \(leftTable.numberOfRows)")
                try? String(window.windowNumber).write(toFile: logPath + ".wid", atomically: true, encoding: .utf8)
                try? JSONSerialization.data(withJSONObject: [key, command ? 1 : 0] + click).write(to: URL(fileURLWithPath: logPath + ".keys-\(index)"))
                for _ in 0..<100 where !fm.fileExists(atPath: logPath + ".sent-\(index)") && !fm.fileExists(atPath: logPath + ".aborted") {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                try? await Task.sleep(for: .seconds(2))
            }
            // 1. F5 (key code 96) copies copy-me.bin to the right pane.
            @MainActor func findItem(_ title: String, in menu: NSMenu?) -> NSMenuItem? {
                for item in menu?.items ?? [] {
                    if item.title == title { return item }
                    if let found = findItem(title, in: item.submenu) { return found }
                }
                return nil
            }
            await press(0, 96, clicking: "copy-me.bin")
            NSApp.mainMenu?.update()
            lines.append("after the click: Copy to Other Pane enabled \(findItem("Copy to Other Pane", in: NSApp.mainMenu)?.isEnabled ?? false) · Get Info enabled \(findItem("Get Info", in: NSApp.mainMenu)?.isEnabled ?? false) · selection \(first.selectedItems.map(\.name)) · pane can send \(first.canSendToOtherPane)")
            lines.append("F5: left \(contents(left)) · right \(contents(right))")
            // 2. F6 (97) moves move-me.bin.
            await press(1, 97, clicking: "move-me.bin")
            for _ in 0..<20 where contents(left).contains("move-me.bin") { try? await Task.sleep(for: .milliseconds(200)) }
            lines.append("F6: left \(contents(left)) · right \(contents(right))")
            // 3. ⌘U (key code 32) swaps the panes' folders.
            await press(2, 32, command: true)
            lines.append("⌘U: left pane shows \(first.current?.lastComponent ?? "?") · right pane shows \(second.current?.lastComponent ?? "?")")
            // 4. View › Columns: hide Size, in both panes.
            @MainActor func visibleColumns() -> [Int] {
                var tables: [NSTableView] = []
                func collect(_ view: NSView) {
                    if let table = view as? NSTableView, table.headerView != nil { tables.append(table) }
                    view.subviews.forEach(collect)
                }
                if let content = window.contentView { collect(content) }
                return tables.map { $0.tableColumns.filter { !$0.isHidden }.count }
            }
            let before = visibleColumns()
            ColumnSettings.shared.toggle("size")
            try? await Task.sleep(for: .seconds(1))
            let after = visibleColumns()
            ColumnSettings.shared.toggle("size")
            try? await Task.sleep(for: .milliseconds(500))
            lines.append("Columns › Size: visible columns per pane \(before) → hidden \(after) → shown again \(visibleColumns())")
            try? fm.removeItem(at: root)
            lines.append("done")
        }
    }

    /// `-BlitLayoutShot <log> -BlitLayoutLeft <path> -BlitLayoutRight <path>
    /// [-BlitLayoutWidth 1440]`: opens the two panes on real folders at a typical
    /// window size for a design review, then writes the window number to
    /// <log>.wid so a screenshot of just this window can be taken from outside.
    static func runLayoutShotIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitLayoutShot"),
              let left = UserDefaults.standard.string(forKey: "BlitLayoutLeft"),
              let right = UserDefaults.standard.string(forKey: "BlitLayoutRight") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard let first = BrowserModel.active, let window = BrowserModel.activeWindow,
                  let second = BrowserModel.oppositePane?(first) else { return }
            first.open(.local(URL(fileURLWithPath: left)))
            second.open(.local(URL(fileURLWithPath: right)))
            let width = UserDefaults.standard.double(forKey: "BlitLayoutWidth")
            window.setFrame(NSRect(x: 100, y: 100, width: width > 0 ? width : 1440, height: 860), display: true)
            try? await Task.sleep(for: .seconds(3))
            if let row = first.rows.first(where: { !$0.isDirectory }) ?? first.rows.first { first.selection = [row.id] }
            try? await Task.sleep(for: .seconds(1))
            var tables: [NSTableView] = []
            func collect(_ view: NSView) {
                if let table = view as? NSTableView, table.headerView != nil { tables.append(table) }
                view.subviews.forEach(collect)
            }
            if let content = window.contentView { collect(content) }
            let widths = tables.map { table in
                "visible \(Int(table.enclosingScrollView?.contentView.bounds.width ?? 0)): " +
                table.tableColumns.filter { !$0.isHidden }.map { "\($0.title) \(Int($0.width))" }.joined(separator: ", ")
            }
            try? widths.joined(separator: "\n").write(toFile: logPath + ".log", atomically: true, encoding: .utf8)
            try? String(window.windowNumber).write(toFile: logPath + ".wid", atomically: true, encoding: .utf8)
        }
    }

    /// `-BlitTabsTest <log>`: tabs of pairs (R2.18), without real input: each
    /// tab keeps its folders and scroll, the File and Window menus' keys (sent
    /// to this copy's own menus, never posted to the system), reordering,
    /// renaming, closing, and a picture of the bar (`<log>.wid`, then the
    /// shell writes `<log>.shot` once it has captured the window).
    static func runTabsTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitTabsTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-tabs-test")
            try? fm.removeItem(at: root)
            let names = ["Seedbox Downloads", "SSD Movies", "Photography", "NAS TV Shows"]
            let folders = names.map { root.appendingPathComponent($0) }
            for folder in folders {
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                for i in 0..<80 { fm.createFile(atPath: folder.appendingPathComponent(String(format: "file-%02d.mkv", i)).path, contents: Data("x".utf8)) }
            }
            let tabs = PaneTabs.shared
            guard let window = BrowserModel.activeWindow, let tab1 = tabs.current, let second1 = tab1.second else {
                return lines.append("no window or second pane")
            }
            window.setFrame(NSRect(x: 100, y: 100, width: 1280, height: 760), display: true)
            // Key within this copy (the menus follow the key window), without
            // bringing it in front of the user's apps.
            window.makeKey()
            tab1.first.open(.local(folders[0]))
            second1.open(.local(folders[1]))
            for _ in 0..<30 where tab1.first.rows.count < 80 { try? await Task.sleep(for: .milliseconds(200)) }
            try? await Task.sleep(for: .seconds(1))
            @MainActor func clip(_ model: BrowserModel) -> NSClipView? {
                guard let anchor = EmptySpaceMenu.anchorView(for: model), let content = window.contentView else { return nil }
                let frame = anchor.convert(anchor.bounds, to: nil)
                let centre = NSPoint(x: frame.midX, y: frame.midY)
                var found: NSClipView?
                func search(_ view: NSView) {
                    if found == nil, let table = view as? NSTableView, table.headerView != nil, let scroll = table.enclosingScrollView,
                       scroll.convert(scroll.bounds, to: nil).contains(centre) { found = scroll.contentView }
                    view.subviews.forEach(search)
                }
                search(content)
                return found
            }
            clip(tab1.first)?.scroll(to: NSPoint(x: 0, y: 600))
            try? await Task.sleep(for: .milliseconds(300))
            lines.append("tab 1 scrolled to \(Int(clip(tab1.first)?.bounds.origin.y ?? -1))")

            // ⌘T: a new tab with the same pair, then new folders in it.
            tabs.newTab()
            try? await Task.sleep(for: .seconds(1))
            guard let tab2 = tabs.current, tab2.id != tab1.id else { return lines.append("⌘T made no tab") }
            lines.append("new tab: \(tabs.tabs.count) tabs · shows \(tab2.first.current?.lastComponent ?? "-") | \(tab2.second?.current?.lastComponent ?? "-") · bar shown \(tabs.tabs.count > 1)")
            tab2.first.open(.local(folders[2]))
            tab2.second?.open(.local(folders[3]))
            try? await Task.sleep(for: .seconds(1))
            lines.append("tab 2 now \(tab2.first.current?.lastComponent ?? "-") | \(tab2.second?.current?.lastComponent ?? "-") · tab 1 still \(tab1.first.current?.lastComponent ?? "-") | \(tab1.second?.current?.lastComponent ?? "-")")
            lines.append("titles: \(tabs.tabs.map { $0.title(twoPanes: true, servers: tab1.first.servers) })")
            lines.append("menus see tab 2: first is tab 2's \(Panes.shared.first === tab2.first) · active pane is tab 2's \(BrowserModel.active === tab2.first || BrowserModel.active === tab2.second)")

            // The menus, and their keys sent to this copy's own main menu.
            NSApp.mainMenu?.update()
            @MainActor func describe(_ title: String) -> String {
                guard let menu = NSApp.mainMenu?.items.first(where: { $0.title == title })?.submenu else { return "\(title): missing" }
                menu.update()
                return "\(title): " + menu.items.filter { !$0.isSeparatorItem }.map { item in
                    var mods = ""
                    if item.keyEquivalentModifierMask.contains(.control) { mods += "⌃" }
                    if item.keyEquivalentModifierMask.contains(.option) { mods += "⌥" }
                    if item.keyEquivalentModifierMask.contains(.shift) { mods += "⇧" }
                    if item.keyEquivalentModifierMask.contains(.command) { mods += "⌘" }
                    let key = item.keyEquivalent == "\t" ? "Tab" : item.keyEquivalent.uppercased()
                    return item.title + (key.isEmpty ? "" : " \(mods)\(key)") + (item.isEnabled ? "" : " (off)")
                }.joined(separator: ", ")
            }
            lines.append("window key \(window.isKeyWindow)")
            lines.append(describe("File"))
            lines.append(describe("Window"))
            @MainActor func key(_ characters: String, _ flags: NSEvent.ModifierFlags, code: UInt16) -> Bool {
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                                   windowNumber: window.windowNumber, context: nil, characters: characters,
                                                   charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return false }
                NSApp.mainMenu?.update()
                return NSApp.mainMenu?.performKeyEquivalent(with: event) ?? false
            }
            let one = key("1", .command, code: 18)
            try? await Task.sleep(for: .seconds(1))
            lines.append("⌘1 handled \(one): shows tab \((tabs.selectedIndex ?? -1) + 1) · \(tabs.current?.first.current?.lastComponent ?? "-")")
            lines.append("tab 1 scroll restored to \(Int(clip(tab1.first)?.bounds.origin.y ?? -1)) (was 600)")
            let next = key("\t", .control, code: 48)
            try? await Task.sleep(for: .milliseconds(500))
            lines.append("⌃Tab handled \(next): shows tab \((tabs.selectedIndex ?? -1) + 1)")
            let previous = key("\u{19}", [.control, .shift], code: 48)
            try? await Task.sleep(for: .milliseconds(500))
            lines.append("⌃⇧Tab handled \(previous): shows tab \((tabs.selectedIndex ?? -1) + 1)")

            // A third tab, reordering, renaming.
            tabs.newTab()
            try? await Task.sleep(for: .milliseconds(500))
            let tab3 = tabs.current
            tabs.move(tab3!.id, to: 0)
            lines.append("moved the new tab first: order \(tabs.tabs.map { t in t.id == tab1.id ? "1" : t.id == tab2.id ? "2" : "3" }) · shown index \((tabs.selectedIndex ?? -1) + 1)")
            tabs.rename(tab3!.id, to: "  Review  ")
            lines.append("renamed: \(tab3!.title(twoPanes: true, servers: tab1.first.servers)) · cleared: \({ tabs.rename(tab3!.id, to: ""); return tab3!.title(twoPanes: true, servers: tab1.first.servers) }())")
            tabs.rename(tab2.id, to: "Archive")

            // ⌘W with several tabs closes the shown tab, not the window.
            let close = key("w", .command, code: 13)
            try? await Task.sleep(for: .milliseconds(500))
            lines.append("⌘W handled \(close): \(tabs.tabs.count) tabs · window still open \(window.isVisible) · shows \(tabs.current?.title(twoPanes: true, servers: tab1.first.servers) ?? "-")")

            // The picture: three tabs, one of them touching the fake transfer's folder.
            tabs.newTab()
            try? await Task.sleep(for: .milliseconds(500))
            tabs.current?.first.open(.local(URL(fileURLWithPath: "/tmp")))
            tabs.select(tab1.id)
            try? await Task.sleep(for: .seconds(2))
            lines.append("tabs for the picture: \(tabs.tabs.map { $0.title(twoPanes: true, servers: tab1.first.servers) })")
            try? String(window.windowNumber).write(toFile: logPath + ".wid", atomically: true, encoding: .utf8)
            for _ in 0..<100 where !fm.fileExists(atPath: logPath + ".shot") { try? await Task.sleep(for: .milliseconds(100)) }

            // Closing the rest leaves one tab and hides the bar; the last can't close.
            while tabs.tabs.count > 1 { tabs.close(tabs.tabs.last!.id) }
            tabs.close(tabs.tabs[0].id)
            lines.append("closed down to \(tabs.tabs.count) tab · Close Tab enabled \(NSApp.mainMenu.map { _ in describe("File").contains("Close Tab ⌘W (off)") == false } ?? false)")
            lines.append("done")
        }
    }

    /// `-BlitTabsRestoreTest <log> -BlitTabsStore <suite> -BlitTabsPhase save|check`:
    /// tabs come back on relaunch. `save` sets up three tabs (one named, the
    /// second shown, its right pane active); `check`, a new launch, logs what
    /// came back. The suite is scratch: the user's own tabs are never touched.
    static func runTabsRestoreTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitTabsRestoreTest"),
              let phase = UserDefaults.standard.string(forKey: "BlitTabsPhase") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-tabs-restore")
            let folders = ["A", "B", "C", "D", "E", "F"].map { root.appendingPathComponent($0) }
            let tabs = PaneTabs.shared
            var lines: [String] = []
            if phase == "save" {
                try? fm.removeItem(at: root)
                folders.forEach { try? fm.createDirectory(at: $0, withIntermediateDirectories: true) }
                for pair in 0..<3 {
                    if pair > 0 { tabs.newTab(); try? await Task.sleep(for: .seconds(1)) }
                    tabs.current?.first.open(.local(folders[pair * 2]))
                    tabs.current?.second?.open(.local(folders[pair * 2 + 1]))
                    try? await Task.sleep(for: .milliseconds(500))
                }
                tabs.rename(tabs.tabs[2].id, to: "Archive")
                tabs.select(index: 1)
                tabs.current?.secondActive = true
                tabs.save()
                lines.append("saved \(tabs.tabs.count) tabs")
            } else {
                // The shown tab opens its folders; the others wait until shown.
                try? await Task.sleep(for: .seconds(1))
                lines.append("restored \(tabs.tabs.count) tabs · shown \((tabs.selectedIndex ?? -1) + 1) · right pane active \(tabs.current?.secondActive ?? false)")
                for (index, tab) in tabs.tabs.enumerated() {
                    let open = tab.first.current != nil
                    lines.append("tab \(index + 1): \(tab.firstLocation?.lastComponent ?? "-") | \(tab.secondLocation?.lastComponent ?? "-") · name \(tab.customName ?? "none") · opened \(open)")
                }
                tabs.select(index: 2)
                try? await Task.sleep(for: .seconds(1))
                lines.append("after showing tab 3: \(tabs.current?.first.current?.lastComponent ?? "-") | \(tabs.current?.second?.current?.lastComponent ?? "-")")
            }
            lines.append("done")
            try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }

    /// Where each tab sits in the tab bar (SwiftUI's global space: the
    /// window's content, top-left origin), for the real-input tabs test.
    static var tabFrames: [UUID: CGRect] = [:]

    /// `-BlitTabsKeysTest <log>`: the tabs with real keys and clicks, sent by
    /// scripts/ui-keys (steps 0–7) and ui-drag (one drag), both of which act
    /// only while this copy's window is the one in front.
    static func runTabsKeysTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitTabsKeysTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-tabs-keys")
            try? fm.removeItem(at: root)
            let left = root.appendingPathComponent("Left"), right = root.appendingPathComponent("Right")
            for folder in [left, right] {
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                fm.createFile(atPath: folder.appendingPathComponent("a.bin").path, contents: Data("x".utf8))
            }
            let tabs = PaneTabs.shared
            guard let window = BrowserModel.activeWindow, let tab = tabs.current, let second = tab.second else {
                return lines.append("no window or second pane")
            }
            tab.first.open(.local(left))
            second.open(.local(right))
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.setFrame(NSRect(x: 120, y: 120, width: 1200, height: 700), display: true)
            try? await Task.sleep(for: .seconds(1.5))
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            @MainActor func cg(_ point: NSPoint) -> [Int] {
                let screen = window.convertPoint(toScreen: point)
                return [Int(screen.x), Int(screenHeight - screen.y)]
            }
            @MainActor func tabPoint(_ index: Int) -> [Int] {
                guard tabs.tabs.indices.contains(index), let frame = tabFrames[tabs.tabs[index].id],
                      let content = window.contentView else { return [] }
                // Right of the ⌘-number (hovering there shows the close button).
                return cg(NSPoint(x: frame.midX + 20, y: content.bounds.height - frame.midY))
            }
            // Bring this copy forward with a click on the left list's empty space.
            var tables: [NSTableView] = []
            func collect(_ view: NSView) {
                if let table = view as? NSTableView, table.headerView != nil { tables.append(table) }
                view.subviews.forEach(collect)
            }
            if let content = window.contentView { collect(content) }
            guard let table = tables.min(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }) else {
                return lines.append("no tables")
            }
            let seen = table.visibleRect
            try? JSONSerialization.data(withJSONObject: cg(table.convert(NSPoint(x: seen.midX, y: seen.maxY - 40), to: nil)))
                .write(to: URL(fileURLWithPath: logPath + ".click"))
            for _ in 0..<100 where !fm.fileExists(atPath: logPath + ".clicked") { try? await Task.sleep(for: .milliseconds(100)) }
            try? String(window.windowNumber).write(toFile: logPath + ".wid", atomically: true, encoding: .utf8)
            @MainActor func step(_ index: Int, _ key: Int, _ modifiers: Int, click: [Int] = [], clicks: Int = 1) async {
                var payload = [key, modifiers] + click
                if clicks > 1 { payload.append(clicks) }
                try? JSONSerialization.data(withJSONObject: payload).write(to: URL(fileURLWithPath: logPath + ".keys-\(index)"))
                for _ in 0..<100 where !fm.fileExists(atPath: logPath + ".sent-\(index)") && !fm.fileExists(atPath: logPath + ".aborted") {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                try? await Task.sleep(for: .seconds(1))
            }
            @MainActor func shown() -> Int { (tabs.selectedIndex ?? -1) + 1 }
            lines.append("frontmost is this test copy: \(NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier)")
            await step(0, 17, 1)                                      // ⌘T
            lines.append("⌘T: \(tabs.tabs.count) tabs · shows \(shown()) · \(tabs.current?.first.current?.lastComponent ?? "-") | \(tabs.current?.second?.current?.lastComponent ?? "-")")
            await step(1, 18, 1)                                      // ⌘1
            lines.append("⌘1: shows \(shown())")
            await step(2, 48, 2)                                      // ⌃Tab
            lines.append("⌃Tab: shows \(shown())")
            await step(3, 48, 2 | 4)                                  // ⌃⇧Tab
            lines.append("⌃⇧Tab: shows \(shown())")
            await step(4, -1, 0, click: tabPoint(1))                  // click tab 2
            lines.append("click on tab 2: shows \(shown())")
            await step(5, -1, 0, click: tabPoint(0), clicks: 2)       // double-click tab 1
            lines.append("double-click on tab 1: shows \(shown()) · renaming \(tabs.renamingID == tabs.tabs.first?.id)")
            await step(6, 53, 0)                                      // Escape
            lines.append("Escape: renaming \(tabs.renamingID != nil) · name \(tabs.tabs.first?.customName ?? "none")")
            // Drag tab 1 past tab 2: the two trade places.
            let firstID = tabs.tabs[0].id
            let from = tabPoint(0), to = tabPoint(1)
            if from.count == 2, to.count == 2 {
                try? JSONSerialization.data(withJSONObject: [from[0], from[1], to[0] + 30, to[1]])
                    .write(to: URL(fileURLWithPath: logPath + ".points-0"))
                for _ in 0..<150 where !fm.fileExists(atPath: logPath + ".hover-0") && !fm.fileExists(atPath: logPath + ".aborted") {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                try? await Task.sleep(for: .seconds(2.5))   // ui-drag releases about a second after hovering
            }
            lines.append("drag tab 1 past tab 2: it's now tab \((tabs.tabs.firstIndex { $0.id == firstID } ?? -1) + 1) · shows \(shown())")
            await step(7, 13, 1)                                      // ⌘W
            lines.append("⌘W: \(tabs.tabs.count) tab · window open \(window.isVisible)")
            lines.append("done")
        }
    }

    /// `-BlitEmptyClickTest <log>`: right-clicks below the last row of each
    /// pane (posted to this copy's own event queue: the pointer never moves)
    /// show the folder menu, before and after switching tabs.
    static func runEmptyClickTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitEmptyClickTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-empty-click")
            try? fm.removeItem(at: root)
            let left = root.appendingPathComponent("Left"), right = root.appendingPathComponent("Right")
            for folder in [left, right] {
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let count = UserDefaults.standard.integer(forKey: "BlitEmptyClickRows")
                for i in 0..<(count > 0 ? count : 3) { fm.createFile(atPath: folder.appendingPathComponent("f\(i).bin").path, contents: Data("x".utf8)) }
            }
            guard let window = BrowserModel.activeWindow, let tab = PaneTabs.shared.current, let second = tab.second else {
                return lines.append("no window or second pane")
            }
            let height = UserDefaults.standard.double(forKey: "BlitEmptyClickHeight")
            window.setFrame(NSRect(x: 100, y: 100, width: 1000, height: height > 0 ? height : 760), display: true)
            tab.first.open(.local(left))
            second.open(.local(right))
            try? await Task.sleep(for: .seconds(2))
            var opened: String?
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                nonisolated(unsafe) let menu = note.object as? NSMenu
                MainActor.assumeIsolated {
                    opened = menu?.items.map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " | ") ?? "?"
                    let timer = Timer(timeInterval: 0.3, repeats: false) { _ in MainActor.assumeIsolated { menu?.cancelTrackingWithoutAnimation() } }
                    RunLoop.main.add(timer, forMode: .eventTracking)
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            @MainActor func tables() -> [NSTableView] {
                var found: [NSTableView] = []
                func collect(_ view: NSView) {
                    if let table = view as? NSTableView, table.headerView != nil { found.append(table) }
                    view.subviews.forEach(collect)
                }
                if let content = window.contentView { collect(content) }
                return found.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
            }
            @MainActor func click(_ label: String) async {
                for (side, table) in zip(["left", "right"], tables()) {
                  guard let scroll = table.enclosingScrollView else { continue }
                  let last = table.rect(ofRow: max(0, table.numberOfRows - 1))
                  let visible = scroll.convert(scroll.bounds, to: nil)
                  let lastBottom = table.convert(NSPoint(x: last.midX, y: last.maxY), to: nil)
                  lines.append("\(label) \(side): rows \(table.numberOfRows) · scroll view y \(Int(visible.minY))…\(Int(visible.maxY)) · last row bottom y \(Int(lastBottom.y)) · inset \(scroll.contentInsets.bottom)")
                  // From just below the last row down to the bottom of the scroll view.
                  var ys: [CGFloat] = []
                  var y = lastBottom.y - 4
                  while y > visible.minY + 2 && ys.count < 6 { ys.append(y); y -= 10 }
                  for y in ys {
                    let point = NSPoint(x: lastBottom.x, y: y)
                    let hit = window.contentView?.hitTest(window.contentView!.convert(point, from: nil))
                    var chain: [String] = []
                    var view = hit
                    while let current = view, chain.count < 6 { chain.append(String(describing: type(of: current))); view = current.superview }
                    let row = table.row(at: table.convert(point, from: nil))
                    let anchored = EmptySpaceMenu.browser(at: point, in: window) != nil
                    opened = nil
                    guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                         context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { continue }
                    NSApp.postEvent(event, atStart: false)
                    try? await Task.sleep(for: .milliseconds(1200))
                    lines.append("  y \(Int(y)): \(opened == nil ? "NO MENU" : "menu") · row \(row) · anchored \(anchored) · hit \(chain.prefix(3).joined(separator: " < "))")
                    if y == ys.first {
                        opened = nil
                        if let control = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: .control,
                                                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                            context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                            NSApp.postEvent(control, atStart: false)
                            try? await Task.sleep(for: .milliseconds(1200))
                        }
                        lines.append("  ⌃-click y \(Int(y)): \(opened == nil ? "NO MENU" : "menu")")
                        // A plain click there shows nothing (it only clears the selection).
                        opened = nil
                        if let plain = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                                          timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                           let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                                       timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                       context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
                            NSApp.postEvent(plain, atStart: false)
                            NSApp.postEvent(up, atStart: false)
                            try? await Task.sleep(for: .milliseconds(800))
                        }
                        lines.append("  plain click y \(Int(y)): \(opened == nil ? "no menu (right)" : "MENU (wrong)")")
                    }
                  }
                }
            }
            // A right-click on a row gets the file menu, on a header the columns menu.
            if let table = tables().first {
                for (label, local) in [("row", NSPoint(x: table.rect(ofRow: 0).midX, y: table.rect(ofRow: 0).midY)),
                                       ("header", NSPoint(x: 60, y: (table.headerView?.bounds.midY ?? 10)))] {
                    let point = label == "row" ? table.convert(local, to: nil) : (table.headerView?.convert(local, to: nil) ?? .zero)
                    opened = nil
                    if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
                                                      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(event, atStart: false)
                        try? await Task.sleep(for: .milliseconds(1200))
                    }
                    lines.append("right-click on a \(label): \(opened.map { String($0.prefix(70)) } ?? "NO MENU")")
                }
            }
            await click("one tab")
            PaneTabs.shared.newTab()
            try? await Task.sleep(for: .seconds(2))
            await click("new tab")
            PaneTabs.shared.select(index: 0)
            try? await Task.sleep(for: .seconds(2))
            await click("back on tab 1")
            lines.append("done")
        }
    }

    /// `-BlitRowDragTest <log>`: Finder's drag rule, with events posted to
    /// this copy's own queue (the pointer never moves): pressing on the date
    /// and moving down selects rows as it goes; pressing on a name keeps a
    /// file drag possible.
    static func runRowDragTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitRowDragTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let folder = fm.temporaryDirectory.appendingPathComponent("blit-row-drag")
            try? fm.removeItem(at: folder)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["a.mkv", "b.mkv", "c.mkv", "d.mkv", "e.mkv", "f.mkv"] {
                fm.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data("x".utf8))
            }
            guard let window = BrowserModel.activeWindow, let browser = PaneTabs.shared.current?.first else { return lines.append("no window") }
            window.setFrame(NSRect(x: 100, y: 100, width: 1200, height: 700), display: true)
            browser.open(.local(folder))
            browser.sortOrder = [KeyPathComparator(\FileItem.name)]
            try? await Task.sleep(for: .seconds(2))
            var tables: [NSTableView] = []
            func collect(_ view: NSView) {
                if let table = view as? NSTableView, table.headerView != nil { tables.append(table) }
                view.subviews.forEach(collect)
            }
            if let content = window.contentView { collect(content) }
            guard let table = tables.min(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }),
                  let nameColumn = table.tableColumns.firstIndex(where: { $0.title == "Name" }),
                  let dateColumn = table.tableColumns.firstIndex(where: { $0.title == "Modified" }) else { return lines.append("no table") }
            let names = browser.rows.map(\.name)
            lines.append("rows \(names)")
            @MainActor func point(row: Int, column: Int, x: CGFloat? = nil) -> NSPoint {
                let rect = table.frameOfCell(atColumn: column, row: row)
                return table.convert(NSPoint(x: x ?? rect.midX, y: rect.midY), to: nil)
            }
            @MainActor func post(_ type: NSEvent.EventType, _ at: NSPoint) {
                if let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                                  pressure: type == .leftMouseUp ? 0 : 1) {
                    NSApp.postEvent(event, atStart: false)
                }
            }
            // Where the name ends in the first row (the cell measures its content).
            let cell = table.view(atColumn: nameColumn, row: 0, makeIfNecessary: false)
            let nameRect = table.rect(ofColumn: nameColumn)
            lines.append("name column \(Int(nameRect.minX))…\(Int(nameRect.maxX)) · cell content width \(Int(cell?.fittingSize.width ?? -1))")
            for (label, x) in [("on the name", nameRect.minX + 40), ("blank part of the Name column", nameRect.maxX - 20)] {
                let local = NSPoint(x: x, y: table.rect(ofRow: 0).midY)
                lines.append("press \(label): moves files \(RowDragRule.isOnName(local, in: table, browser: browser))")
            }
            // Press on the date of the first row, move down over three more, release.
            let start = point(row: 0, column: dateColumn)
            post(.leftMouseDown, start)
            for row in 1...3 { post(.leftMouseDragged, point(row: row, column: dateColumn)) }
            post(.leftMouseUp, point(row: 3, column: dateColumn))
            try? await Task.sleep(for: .seconds(1.5))
            lines.append("press on the date: pressed off the name \(RowDragRule.pressedOffName)")
            // A press on a name sets the table up for a file drag again.
            post(.leftMouseDown, point(row: 4, column: nameColumn, x: nameRect.minX + 40))
            post(.leftMouseUp, point(row: 4, column: nameColumn, x: nameRect.minX + 40))
            try? await Task.sleep(for: .seconds(1))
            lines.append("press on a name: pressed off the name \(RowDragRule.pressedOffName)")
            lines.append("done")
        }
    }

    /// `-BlitRowDragRealTest <log>`: Finder's drag rule with a real drag
    /// (scripts/ui-drag, only into this copy's window): pressing on the first
    /// row's date and moving down over three more rows selects the four.
    static func runRowDragRealTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitRowDragRealTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let folder = fm.temporaryDirectory.appendingPathComponent("blit-row-drag-real")
            try? fm.removeItem(at: folder)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            for name in ["a.mkv", "b.mkv", "c.mkv", "d.mkv", "e.mkv", "f.mkv"] {
                fm.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data("x".utf8))
            }
            guard let window = BrowserModel.activeWindow, let browser = PaneTabs.shared.current?.first else { return lines.append("no window") }
            browser.open(.local(folder))
            browser.sortOrder = [KeyPathComparator(\FileItem.name)]
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.setFrame(NSRect(x: 120, y: 120, width: 1200, height: 700), display: true)
            try? await Task.sleep(for: .seconds(2))
            var tables: [NSTableView] = []
            func collect(_ view: NSView) {
                if let table = view as? NSTableView, table.headerView != nil { tables.append(table) }
                view.subviews.forEach(collect)
            }
            if let content = window.contentView { collect(content) }
            guard let table = tables.min(by: { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }),
                  let dateColumn = table.tableColumns.firstIndex(where: { $0.title == "Modified" }) else { return lines.append("no table") }
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            @MainActor func cg(row: Int) -> [Double] {
                let rect = table.frameOfCell(atColumn: dateColumn, row: row)
                let screen = window.convertPoint(toScreen: table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil))
                return [screen.x, screenHeight - screen.y]
            }
            try? String(window.windowNumber).write(toFile: logPath + ".wid", atomically: true, encoding: .utf8)
            try? JSONSerialization.data(withJSONObject: cg(row: 0) + cg(row: 3)).write(to: URL(fileURLWithPath: logPath + ".points-0"))
            for _ in 0..<150 where !fm.fileExists(atPath: logPath + ".hover-0") && !fm.fileExists(atPath: logPath + ".aborted") {
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .seconds(2.5))
            lines.append("frontmost is this test copy: \(NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier)")
            lines.append("drag down from the date of row 1 to row 4: selected \(browser.selectedItems.map(\.name).sorted()) · files still there \(((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).count)")
            lines.append("done")
        }
    }

    /// The demo transfer for the website's pictures: a camera shoot coming in
    /// from a server to the SSD's Incoming folder, two thirds done.
    static func demoJob(destination: URL) -> TransferJob {
        var server = ServerConfig()
        server.name = "Server"
        let job = TransferJob(kind: .download(server), sources: [.remote(server.id, RemotePath("downloads/SHOOT_2026-09"))],
                              destination: destination, title: "SHOOT_2026-09", destinationName: "Incoming")
        job.persistent = false
        job.status = .running
        job.startedAt = Date().addingTimeInterval(-551)
        job.fileCount = 26; job.filesFinished = 17; job.filesVerified = 17
        job.totalBytes = 61_200_000_000; job.counter.add(40_900_000_000)
        job.connections = 3; job.link = "3× · 255K×32 · EN7"; job.rttMilliseconds = 148
        job.rate = 74.2; job.peakRate = 81.3; job.hashCacheHits = 5
        job.history = (0..<60).map { i in 62 + 12 * sin(Double(i) / 5) + Double(i % 7) }
        job.connectionRates = [25.1, 23.8, 25.3]
        job.hashed = ["A001_C017.MOV": 2_600_000_000]; job.hashSizes = ["A001_C017.MOV": 4_100_000_000]
        for text in ["CONNECT · 3 CONNECTIONS · 255K×32 · EN7", "RESUME A001_C015.MOV · 1.4 GB ON DISK",
                     "✓ SHA256 9F3A1C… VERIFIED · A001_C015.MOV", "DOWNLOADED A001_C016.MOV · VERIFYING",
                     "✓ SHA256 2B77E0… VERIFIED · A001_C016.MOV · SERVER CACHE", "GET A001_C018.MOV → INCOMING"] {
            job.note(text)
        }
        return job
    }

    /// `-BlitDemoShot <log> -BlitDemoSSD <volume> -BlitDemoArchive <volume>`:
    /// the window for the website, from made-up folders on two scratch disk
    /// images: a demo sidebar, three tabs, the demo transfer in the full HUD.
    /// Writes `<log>.wid` and waits for `<log>.shot` (the shell captures it).
    static func runDemoShotIfRequested(sidebar: SidebarModel, transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitDemoShot") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard let (window, tab, incoming) = await demoSetUp(sidebar: sidebar) else { return }
            transfers.debugAppend([demoJob(destination: incoming)])
            transfers.isExpanded = true
            if let row = tab.first.rows.first(where: { $0.name == "Interview_A-cam.mov" }) { tab.first.selection = [row.id] }
            try? await Task.sleep(for: .seconds(2))
            // In front for the picture (an inactive window greys its controls).
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(1.5))
            try? String(window.windowNumber).write(toFile: logPath + ".wid", atomically: true, encoding: .utf8)
            for _ in 0..<300 where !FileManager.default.fileExists(atPath: logPath + ".shot") { try? await Task.sleep(for: .milliseconds(100)) }
            try? "done\n".write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }

    /// The demo window (-BlitDemoSSD <volume> -BlitDemoArchive <volume>): made-up
    /// folders on two scratch disk images, a demo sidebar (none of the Mac's
    /// real drives, shares or devices) and three tabs, the first showing
    /// Incoming beside Projects. Returns the window, that tab and Incoming.
    static func demoSetUp(sidebar: SidebarModel) async -> (NSWindow, PaneTab, URL)? {
        guard let ssdPath = UserDefaults.standard.string(forKey: "BlitDemoSSD"),
              let archivePath = UserDefaults.standard.string(forKey: "BlitDemoArchive") else { return nil }
        let ssd = URL(fileURLWithPath: ssdPath), archive = URL(fileURLWithPath: archivePath)
        let incoming = ssd.appendingPathComponent("Incoming"), projects = archive.appendingPathComponent("Projects")
        let color = ssd.appendingPathComponent("Grading"), films = archive.appendingPathComponent("Films")
        let nas = { (name: String) in VolumeLocation(url: URL(fileURLWithPath: "/Volumes/\(name)"), name: name, isInternal: false, host: "Studio NAS") }
        sidebar.showDemo(
            drives: [VolumeLocation(url: URL(fileURLWithPath: "/"), name: "Macintosh HD", isInternal: true),
                     VolumeLocation(url: ssd, name: ssd.lastPathComponent, isInternal: false),
                     VolumeLocation(url: archive, name: archive.lastPathComponent, isInternal: false)],
            devices: [NetworkDevice(name: "Studio NAS", model: "Xserve", shares: [nas("Media"), nas("Projects")])],
            favorites: [.local(incoming), .local(projects), .local(color), .local(films)])
        guard let window = BrowserModel.activeWindow, let tab = PaneTabs.shared.current, let second = tab.second else { return nil }
        window.setFrame(NSRect(x: 80, y: 60, width: 1440, height: 900), display: true)
        tab.first.open(.local(incoming))
        second.open(.local(projects))
        try? await Task.sleep(for: .seconds(1))
        // Two more tabs, not shown (their folders open only when shown).
        PaneTabs.shared.debugAppend(first: .local(color), second: .local(films))
        PaneTabs.shared.debugAppend(first: .local(films), second: .local(URL(fileURLWithPath: "/Volumes/Media")), name: "Delivery")
        try? await Task.sleep(for: .seconds(1))
        return (window, tab, incoming)
    }

    /// `-BlitDemoVideo <log>` with the demo volumes: the demo for Lemon
    /// Squeezy's review, a real transfer on camera. Writes `<log>.frame` (the
    /// window, CG coordinates) and waits for `<log>.recording`, then: a look
    /// at another tab, back, SHOOT_2026-09 selected and sent to the other pane
    /// (F5's command: a real, SHA-256-verified copy between the two volumes
    /// in the full HUD), and the copied folder opened, every file ✓.
    /// Writes `<log>` when it's over.
    static func runDemoVideoIfRequested(sidebar: SidebarModel, transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitDemoVideo") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath + ".steps", atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard let (window, tab, _) = await demoSetUp(sidebar: sidebar), let second = tab.second else { return lines.append("no demo") }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            try? await Task.sleep(for: .seconds(1.5))
            let frame = window.frame, height = NSScreen.screens.first?.frame.height ?? 0
            try? "\(Int(frame.minX)),\(Int(height - frame.maxY)),\(Int(frame.width)),\(Int(frame.height))"
                .write(toFile: logPath + ".frame", atomically: true, encoding: .utf8)
            for _ in 0..<300 where !FileManager.default.fileExists(atPath: logPath + ".recording") { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .seconds(2.5))
            PaneTabs.shared.select(index: 1)                      // another pair
            lines.append("tab 2")
            try? await Task.sleep(for: .seconds(2.5))
            PaneTabs.shared.select(index: 0)                      // back
            lines.append("tab 1")
            try? await Task.sleep(for: .seconds(2))
            guard let shoot = tab.first.rows.first(where: { $0.name == "SHOOT_2026-09" }) else { return lines.append("no shoot folder") }
            tab.first.selection = [shoot.id]
            BrowserModel.onInteraction?(tab.first)
            try? await Task.sleep(for: .seconds(1.5))
            tab.first.sendToOtherPane(move: false)                // F5
            lines.append("F5")
            for _ in 0..<1200 {
                try? await Task.sleep(for: .milliseconds(100))
                if let job = transfers.jobs.last, !job.isOperation, job.status == .finished { break }
            }
            lines.append("copy: \(transfers.jobs.last.map { "\($0.status) · \($0.filesVerified)/\($0.fileCount) verified" } ?? "none")")
            try? await Task.sleep(for: .seconds(3))
            if let copied = second.rows.first(where: { $0.name == "SHOOT_2026-09" }) {
                second.selection = [copied.id]
                second.toggleExpanded(copied)
            }
            try? await Task.sleep(for: .seconds(5))
            lines.append("done")
            try? "done\n".write(toFile: logPath, atomically: true, encoding: .utf8)
        }
    }

    /// `-BlitRenderCard <png>`: the 1200 × 630 link-preview card (Open Graph,
    /// X): the pixel icon, name and line, over the full HUD with the demo
    /// transfer. `-BlitRenderCardSize 1280x720` renders the YouTube thumbnail:
    /// the same layout, a little larger.
    static func renderCardIfRequested(transfers: TransferManager) {
        guard let path = UserDefaults.standard.string(forKey: "BlitRenderCard") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let job = demoJob(destination: URL(fileURLWithPath: "/tmp"))
            let size = (UserDefaults.standard.string(forKey: "BlitRenderCardSize") ?? "1200x630")
                .split(separator: "x").compactMap { Double($0) }
            let width = size.count == 2 ? size[0] : 1200, height = size.count == 2 ? size[1] : 630
            let big = height > 630   // the thumbnail: larger type, read small on a phone
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
            .frame(width: big ? 84 : 70, height: big ? 72 : 60)
            let content = VStack(alignment: .leading, spacing: big ? 34 : 26) {
                HStack(alignment: .center, spacing: 24) {
                    RoundedRectangle(cornerRadius: 22).fill(Color(white: 0.07))
                        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(HUDColor.border, lineWidth: 1))
                        .overlay(icon)
                        .frame(width: big ? 124 : 104, height: big ? 124 : 104)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 18) {
                            Text("BLIT").font(HUDFont.label(big ? 68 : 56)).foregroundStyle(HUDColor.bright)
                            Text("Big files, moved fast, proven intact.").font(HUDFont.terminal(big ? 40 : 34)).foregroundStyle(HUDColor.bright)
                        }
                        Text("SFTP · DRIVES · NAS  —  EVERY FILE SHA-256 VERIFIED WHERE IT LANDS")
                            .font(HUDFont.label(big ? 14 : 12)).foregroundStyle(HUDColor.dim)
                    }
                }
                TransferHUD(job: job).environment(transfers).frame(width: width - 112)
            }
            .padding(.horizontal, 56)
            .frame(width: width, height: height, alignment: .center)
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

    /// `-BlitRemoteDragTest <log>`: a server file dragged into a local list
    /// with a real drag (scripts/ui-drag), the case that froze the user's
    /// window: the left pane shows the first saved server's start folder, the
    /// right a scratch folder already holding a file of the same name (so the
    /// drop asks Replace / Keep Both, answered Stop here: nothing downloads).
    /// Logs the drop's events, the longest main-thread stall, whether the drag
    /// ended, and a heartbeat for 10 s after.
    static func runRemoteDragTestIfRequested(servers: ServerStore, transfers: TransferManager? = nil) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitRemoteDragTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        var lastBeat = Date(), longest: TimeInterval = 0
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            MainActor.assumeIsolated {
                longest = max(longest, Date().timeIntervalSince(lastBeat))
                lastBeat = Date()
            }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            guard let server = servers.browsable.first, let tab = PaneTabs.shared.current, let second = tab.second,
                  let window = BrowserModel.activeWindow else { return lines.append("no server or panes") }
            let local = fm.temporaryDirectory.appendingPathComponent("blit-remote-drag")
            try? fm.removeItem(at: local)
            try? fm.createDirectory(at: local, withIntermediateDirectories: true)
            tab.first.open(server.startLocation)
            second.open(.local(local))
            for _ in 0..<100 where tab.first.rows.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            // -BlitRemoteDragChild: a file inside an expanded server folder instead
            // (the user's freeze: the file came from a folder opened in place).
            if UserDefaults.standard.bool(forKey: "BlitRemoteDragChild") {
                for folder in tab.first.rows.filter(\.isDirectory).prefix(8) {
                    tab.first.toggleExpanded(folder)
                    for _ in 0..<50 where tab.first.loadingChildren.contains(folder.location) || !tab.first.expanded.contains(folder.location) {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                    if tab.first.rows.contains(where: { $0.depth == 1 && !$0.isDirectory }) { break }
                    tab.first.toggleExpanded(folder)
                }
            }
            let childOnly = UserDefaults.standard.bool(forKey: "BlitRemoteDragChild")
            // The smallest file at the top of the server folder, with a namesake here.
            guard let file = tab.first.rows.filter({ !$0.isDirectory && (!childOnly || $0.depth == 1) })
                    .min(by: { ($0.size ?? .max) < ($1.size ?? .max) }) else {
                return lines.append("no file on the server (\(tab.first.rows.count) rows, error \(tab.first.error ?? "none"))")
            }
            let name = ConflictPrompt.name(for: file.location)
            // -BlitRemoteDragTwice: the first drag downloads the file for real, the
            // second drags it again onto its verified copy (the user's freeze).
            let twice = UserDefaults.standard.bool(forKey: "BlitRemoteDragTwice")
            if !twice { fm.createFile(atPath: local.appendingPathComponent(name).path, contents: Data("x".utf8)) }
            second.reload()
            // -BlitRemoteDragRealPrompt: the real Replace / Keep Both sheet (answered
            // Stop below, if it appears), as the user saw it.
            let realPrompt = UserDefaults.standard.bool(forKey: "BlitRemoteDragRealPrompt")
            if !realPrompt { ConflictPrompt.testAnswer = .stop }
            window.setFrame(NSRect(x: 120, y: 120, width: 1200, height: 700), display: true)
            // In front before the drag (ui-drag refuses otherwise); macOS can take a moment.
            for _ in 0..<20 where NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? await Task.sleep(for: .seconds(1))
            var tables: [NSTableView] = []
            func collect(_ view: NSView) {
                if let table = view as? NSTableView, table.headerView != nil { tables.append(table) }
                view.subviews.forEach(collect)
            }
            if let content = window.contentView { collect(content) }
            tables.sort { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
            guard tables.count == 2, let row = tab.first.rows.firstIndex(where: { $0.id == file.id }) else { return lines.append("tables \(tables.count)") }
            let height = NSScreen.screens.first?.frame.height ?? 0
            @MainActor func cg(_ table: NSTableView, _ p: NSPoint) -> [Double] {
                let s = window.convertPoint(toScreen: table.convert(p, to: nil)); return [s.x, height - s.y]
            }
            let rect = tables[0].rect(ofRow: row)
            let from = cg(tables[0], NSPoint(x: rect.minX + 90, y: rect.midY))
            let seen = tables[1].visibleRect
            let to = cg(tables[1], NSPoint(x: seen.midX, y: seen.minY + seen.height * 0.6))
            lines.append("frontmost is this test copy: \(NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier) · dragging \(name) (\(file.size ?? -1) bytes, depth \(file.depth)) from \(server.displayName)")
            UITestHarness.dropTrail = []
            longest = 0
            try? String(window.windowNumber).write(toFile: logPath + ".wid", atomically: true, encoding: .utf8)
            try? JSONSerialization.data(withJSONObject: from + to).write(to: URL(fileURLWithPath: logPath + ".points-0"))
            for _ in 0..<200 where !fm.fileExists(atPath: logPath + ".hover-0") && !fm.fileExists(atPath: logPath + ".aborted") {
                try? await Task.sleep(for: .milliseconds(100))
            }
            lines.append("hovering: stall so far \(String(format: "%.1f", longest)) s · trail \(UITestHarness.dropTrail.suffix(4))")
            try? await Task.sleep(for: .seconds(4))
            if realPrompt {
                let sheet = window.attachedSheet
                lines.append("real prompt: sheet on the window \(sheet != nil) · key window is the main one \(NSApp.keyWindow === window) · windows \(NSApp.windows.filter(\.isVisible).map { "\(type(of: $0))" })")
                if let sheet { window.endSheet(sheet, returnCode: NSApplication.ModalResponse(rawValue: 1003)) }   // Stop
                try? await Task.sleep(for: .seconds(1))
            }
            if twice {
                for _ in 0..<150 {
                    try? await Task.sleep(for: .milliseconds(200))
                    if let job = transfers?.jobs.last, !job.isOperation, job.status == .finished { break }
                }
                lines.append("first drag: \(transfers?.jobs.last.map { "\($0.status) · \($0.filesVerified)/\($0.fileCount) verified" } ?? "no job") · file here \(fm.fileExists(atPath: local.appendingPathComponent(name).path))")
                try? await Task.sleep(for: .seconds(2))
                second.reload()
                try? await Task.sleep(for: .seconds(1))
                UITestHarness.dropTrail = []
                longest = 0
                try? JSONSerialization.data(withJSONObject: from + to).write(to: URL(fileURLWithPath: logPath + ".points-1"))
                for _ in 0..<200 where !fm.fileExists(atPath: logPath + ".hover-1") && !fm.fileExists(atPath: logPath + ".aborted") {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                try? await Task.sleep(for: .seconds(4))
                let sheet = window.attachedSheet
                lines.append("second drag: sheet on the window \(sheet != nil) · stall \(String(format: "%.1f", longest)) s · drop performed \(UITestHarness.dropTrail.contains { $0.hasPrefix("perform") }) · trail \(UITestHarness.dropTrail.filter { !$0.hasPrefix("updated") && !$0.hasPrefix("provider") })")
                if let sheet { window.endSheet(sheet, returnCode: NSApplication.ModalResponse(rawValue: 1003)) }
            }
            lines.append("after release: stall \(String(format: "%.1f", longest)) s · drop performed \(UITestHarness.dropTrail.contains { $0.hasPrefix("perform") }) · asked \(ConflictPrompt.lastAsked.map { "\($0.count) conflict(s)" } ?? "no") · trail \(UITestHarness.dropTrail.filter { !$0.hasPrefix("updated") })")
            for second in 1...10 {
                try? await Task.sleep(for: .seconds(1))
                if second % 5 == 0 { lines.append("heartbeat +\(second) s · longest stall \(String(format: "%.1f", longest)) s") }
            }
            ConflictPrompt.testAnswer = nil
            lines.append("done")
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
