// Debug builds only: a self-test for right-click menus, since they can't be
// checked from outside the app without Accessibility access. Launch with
// `-BlitRightClickTest /path/to/log.txt`: Blit opens a small temporary folder,
// sends itself right-clicks at a few points, writes which menu opened at each
// (or none), then goes back.

#if DEBUG
import AppKit
import QuartzCore
import AVFoundation
import BlitLocal
import BlitRemote
import BlitSFTP
import CryptoKit
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
        let paused = job([]); paused.status = .paused
        let trash = TransferJob(kind: .operation(verb: "TRASH", done: "MOVED TO TRASH"), sources: [.local(URL(fileURLWithPath: "/tmp/Some.Film.2160p.torrent"))],
                                destination: URL(fileURLWithPath: "/tmp"), title: "Some.Film.2160p.torrent", destinationName: "Trash")
        trash.persistent = false
        trash.status = .finished
        trash.fileCount = 1
        trash.filesFinished = 1
        trash.failures = ["Some.Film.2160p.torrent: “Some.Film.2160p.torrent” couldn’t be moved to the Trash because the volume doesn’t support it."]
        let pausing = job([]); pausing.stopRequest = .pause
        transfers.notice("Can't put a folder inside itself.", action: "MOVE", place: "Incoming")
        transfers.notice("“untitled folder” already exists in “Movies”.", action: "NEW FOLDER")
        let notices = transfers.jobs.suffix(2)
        let content = VStack(spacing: 8) {
            TransferStrip(job: running).frame(width: 900)
            TransferStrip(job: paused).frame(width: 900)
            TransferStrip(job: pausing).frame(width: 900)
            TransferHUD(job: running).frame(width: 900)
            TransferStrip(job: failed).frame(width: 900)
            TransferStrip(job: trash).frame(width: 900)
            WarningsPopover(job: trash) {}
            WarningsPopover(job: failed) {}
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
            // A Find with a space in front (the last rule's " " left in the field) matches nothing; the sheet says so.
            var spaced = RenameRule(); spaced.find = " S01x"; spaced.replacement = "S01E"
            var plain = spaced; plain.find = "S01x"
            let episode = "Tales-from-the-Crypt_S01x01_The-Man-Who-Was-Death.mkv"
            lines.append("find “ S01x”: \(spaced.apply(to: episode, index: 0, date: date)) · find “S01x”: \(plain.apply(to: episode, index: 0, date: date))")
            lines.append("edge spaces: " + [" ", "  ", " S01x", "S01x ", " a ", "S01x", ""].map { "“\(RenameRule.visibleSpaces($0))” \(RenameRule.edgeSpaces($0) ?? "none")" }.joined(separator: " · "))
            // A picture of the sheet with Find “S01x ” (a space left at the end): its own window,
            // behind everything, given the rule (the user's saved one is never read or written).
            let sample = FileManager.default.temporaryDirectory.appendingPathComponent("blit-rename-sheet")
            try? FileManager.default.removeItem(at: sample)
            try? FileManager.default.createDirectory(at: sample, withIntermediateDirectories: true)
            for name in ["Show-Name_S01x01_Pilot.mkv", "Show-Name_S01x02_Second.mkv", "Show-Name_S02x01_Return.mkv"] {
                FileManager.default.createFile(atPath: sample.appendingPathComponent(name).path, contents: nil)
            }
            if let items = try? BrowserModel.listLocal(sample, showHidden: false).sorted(by: { $0.name < $1.name }) {
                var trailing = RenameRule(); trailing.find = "S01x "; trailing.replacement = "S01E"
                let sheet = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 520, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
                sheet.contentView = NSHostingView(rootView: BatchRenameView(browser: browser, items: items, steps: [trailing]))
                sheet.orderBack(nil)
                try? await Task.sleep(for: .seconds(1))
                try? String(sheet.windowNumber).write(toFile: logPath + ".rename-wid", atomically: true, encoding: .utf8)
                for _ in 0..<80 where !FileManager.default.fileExists(atPath: logPath + ".rename-shot") { try? await Task.sleep(for: .milliseconds(100)) }
                sheet.orderOut(nil)
            }
            try? FileManager.default.removeItem(at: sample)
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

    /// `-BlitRenderFullDiskAccess out.png`: the first-launch Full Disk Access
    /// sheet, not granted (out.png) and granted (out-granted.png), and the
    /// warning popover's hint for a Move to Trash macOS turned away
    /// (out-popover.png). Also out.txt: whether this copy has it.
    static func renderFullDiskAccessIfRequested(transfers: TransferManager) {
        guard let path = UserDefaults.standard.string(forKey: "BlitRenderFullDiskAccess") else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let access = FullDiskAccess.shared
            let real = access.isGranted
            try? "this copy: granted \(real) · check \(FullDiskAccess.check()) · would offer \(access.shouldOffer)".write(toFile: path.replacingOccurrences(of: ".png", with: ".txt"), atomically: true, encoding: .utf8)
            @MainActor func picture<V: View>(_ view: V, _ suffix: String) async {
                let host = NSHostingView(rootView: view.environment(transfers))
                let size = host.fittingSize
                let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 80, y: 80), size: size),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: .darkAqua)
                window.contentView = host
                window.orderFront(nil)
                try? await Task.sleep(for: .seconds(1.2))
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path.replacingOccurrences(of: ".png", with: "\(suffix).png")))
                }
                window.orderOut(nil)
            }
            access.debugSet(false)
            await picture(FullDiskAccessSheet().background(Color(nsColor: .windowBackgroundColor)), "")
            let trash = TransferJob(kind: .operation(verb: "TRASH", done: "MOVED TO TRASH"), sources: [.local(URL(fileURLWithPath: "/tmp/Some.Film.torrent"))],
                                    destination: URL(fileURLWithPath: "/tmp"), title: "Some.Film.torrent", destinationName: "Trash")
            trash.persistent = false
            trash.failures = ["Some.Film.torrent: “Some.Film.torrent” couldn’t be moved to the trash because you don’t have permission to access it."]
            await picture(WarningsPopover(job: trash) {}, "-popover")
            access.debugSet(true)
            await picture(FullDiskAccessSheet().background(Color(nsColor: .windowBackgroundColor)), "-granted")
            access.debugRelease()
        }
    }

    /// `-BlitShareTest <log>` (with -BlitIsolatedQueue YES): shares are remembered
    /// with their smb:// address, and mounting one that's already mounted goes
    /// through NetFS without UI (EEXIST) and doesn't disturb it. Also each
    /// share's live connection and whether its password is saved (what the
    /// move to the cable checks; nothing is ejected).
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
                let connection = await ShareTools.live.connection(mountPoint)
                lines.append("    saved password \(ShareMounter.hasSavedPassword(mountPoint)) · connection "
                             + (connection.map { "\($0.interface)\($0.isWiFi ? " (Wi-Fi)" : "") to \($0.server) · new connections via \($0.fresh?.interface ?? "?") · reconnect moves to the cable \($0.reconnectMovesToWired)" } ?? "unknown"))
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

    /// The window's file lists, left to right (the shown ones: a pane with no
    /// folder keeps its list, hidden).
    @MainActor static func fileLists(in window: NSWindow?) -> [NSTableView] {
        var found: [NSTableView] = []
        func collect(_ view: NSView) {
            if let table = view as? FileTableView, !table.isHiddenOrHasHiddenAncestor { found.append(table) }
            view.subviews.forEach(collect)
        }
        if let content = window?.contentView { collect(content) }
        return found.sorted { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }

    @MainActor private static func firstTable(in view: NSView?) -> NSTableView? { fileLists(in: view?.window).first }

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

    /// Stand-in shares for the cable test: where each is connected, which
    /// have a saved password, which refuse to eject, and what was done.
    @MainActor final class FakeShares {
        var servers: [String: String] = [:]            // mounted share → NAS address
        var connections: [String: SMBConnection] = [:]
        var afterRemount: [String: SMBConnection] = [:]
        var saved: Set<String> = []
        var refuse: [String: String] = [:]
        var remountProblem: [String: String] = [:]
        var calls: [String] = []

        var tools: ShareTools {
            ShareTools(
                mounts: { paths in
                    Array(Set(paths.compactMap { path in self.servers.keys.first { path == $0 || path.hasPrefix($0 + "/") } })).sorted()
                },
                connection: { self.connections[$0] },
                known: { self.servers.map { (mountPoint: $0.key, server: $0.value) }.sorted { $0.mountPoint < $1.mountPoint } },
                canRemount: { self.servers[$0] != nil },
                hasSavedPassword: { self.saved.contains($0) },
                eject: { share in
                    let name = (share as NSString).lastPathComponent
                    if let reason = self.refuse[share] { self.calls.append("eject \(name) refused"); return reason }
                    self.calls.append("eject \(name)")
                    self.connections[share] = nil
                    return nil
                },
                remount: { share in
                    self.calls.append("remount \((share as NSString).lastPathComponent)")
                    if let problem = self.remountProblem[share] { return problem }
                    self.connections[share] = self.afterRemount[share]
                    return nil
                })
        }
    }

    /// `-BlitCableTest <log>`: a share stuck on Wi-Fi goes back to the cable
    /// before a transfer uses it, only when that's safe (PRD R1.7). Runs the
    /// real check against stand-in shares, so nothing real is looked at or
    /// ejected; each case logs the LINK label, the route warning, what was
    /// ejected and remounted, and the lines the transfer's log gained.
    static func runCableTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitCableTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            let cable = NetworkPath(interface: "en7", localAddress: "192.168.20.86", isWiFi: false, activeWired: ["en7"])
            let wifiRoute = NetworkPath(interface: "en1", localAddress: "192.168.20.38", isWiFi: true, activeWired: ["en7"])
            func onWiFi(fresh: NetworkPath? = nil, multichannel: Bool = false) -> SMBConnection {
                SMBConnection(server: "192.168.20.12", interface: "en1", isWiFi: true, isMultichannel: multichannel, fresh: fresh ?? cable)
            }
            let onCable = SMBConnection(server: "192.168.20.12", interface: "en7", isWiFi: false, isMultichannel: false, fresh: cable)
            let nas = "/Volumes/FakeNAS", nas2 = "/Volumes/FakeNAS2"
            let fake = FakeShares()
            transfers.shareTools = fake.tools
            transfers.lastCableReconnect = [:]
            @MainActor func job(_ title: String) -> TransferJob {
                TransferJob(kind: .copy, sources: [.local(URL(filePath: "/tmp/blit-cable-test/Pack"))],
                            destination: URL(filePath: nas + "/Incoming"), title: title, destinationName: "Incoming")
            }
            @MainActor func run(_ name: String, _ job: TransferJob) async {
                fake.calls = []
                let label = await transfers.keepSharesOnCable(job)
                lines.append("\(name): link \(label ?? "none") · route \(job.routeWarning ?? "none") · "
                             + (fake.calls.isEmpty ? "nothing ejected" : fake.calls.joined(separator: ", ")))
                for line in job.log { lines.append("    \(line.text)") }
            }
            fake.servers = [nas: "192.168.20.12"]
            fake.saved = [nas]
            fake.connections[nas] = onCable
            await run("on the cable", job("A"))
            fake.connections[nas] = onWiFi()
            fake.afterRemount[nas] = onCable
            await run("on Wi-Fi", job("B"))
            fake.connections[nas] = onWiFi()
            await run("on Wi-Fi again within 10 min", job("C"))
            transfers.lastCableReconnect = [:]
            fake.saved = []
            await run("no saved password", job("D"))
            fake.saved = [nas]
            let busy = job("Busy")
            busy.status = .running
            busy.sharesChecked = true
            transfers.debugInsert(busy)
            await run("another transfer using the share", job("E"))
            transfers.debugRemove(busy)
            fake.connections[nas] = onWiFi(multichannel: true)
            await run("multichannel", job("F"))
            fake.connections[nas] = onWiFi(fresh: wifiRoute)
            await run("cable not on the NAS's network", job("G"))
            fake.servers[nas2] = "192.168.20.12"
            fake.saved.insert(nas2)
            fake.connections[nas] = onWiFi()
            fake.connections[nas2] = onWiFi()
            fake.afterRemount[nas2] = onCable
            await run("two shares on that NAS", job("H"))
            transfers.lastCableReconnect = [:]
            fake.connections[nas] = onWiFi()
            fake.connections[nas2] = onWiFi()
            fake.refuse[nas2] = "Finder is using it"
            fake.afterRemount[nas] = onWiFi()
            await run("the other share won't eject", job("I"))
            fake.refuse = [:]
            fake.servers[nas2] = nil
            fake.afterRemount[nas] = onCable
            transfers.lastCableReconnect = [:]
            fake.connections[nas] = onWiFi()
            fake.calls = []
            let first = job("J1"), second = job("J2")
            let a = Task { await transfers.keepSharesOnCable(first) }
            let b = Task { await transfers.keepSharesOnCable(second) }
            let links = (await a.value, await b.value)
            lines.append("two transfers starting together: links \(links.0 ?? "none") and \(links.1 ?? "none") · \(fake.calls.joined(separator: ", "))")
            transfers.lastCableReconnect = [:]
            fake.connections[nas] = onWiFi()
            fake.remountProblem[nas] = "Couldn't reconnect “FakeNAS” (error 2). Connect it in Finder (Go › Connect to Server)."
            await run("the remount fails", job("K"))
            transfers.shareTools = .live
            transfers.lastCableReconnect = [:]
            lines.append("done")
        }
    }

    /// `-BlitCableLiveTest <log> -BlitCableLiveShare /Volumes/Media`: the move to
    /// the cable for real, on a share that's on the cable already. Its
    /// connection is reported as Wi-Fi once, so Blit ejects and remounts it
    /// with the real tools (nothing is copied or written). Logs each step, the
    /// connection afterwards and whether it's mounted in the same place.
    static func runCableLiveTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitCableLiveTest"),
              let share = UserDefaults.standard.string(forKey: "BlitCableLiveShare") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let live = ShareTools.live
            guard let before = await live.connection(share) else { return lines.append("no SMB connection for \(share)\ndone") }
            lines.append("before: \(before.interface) to \(before.server) · Wi-Fi \(before.isWiFi) · new connections via \(before.fresh?.interface ?? "?")")
            var pretended = false
            var tools = live
            tools.connection = { mountPoint in
                let real = await live.connection(mountPoint)
                guard mountPoint == share, !pretended, let real else { return real }
                pretended = true
                return SMBConnection(server: real.server, interface: "en1", isWiFi: true, isMultichannel: false, fresh: real.fresh)
            }
            tools.eject = { mountPoint in
                let start = Date()
                let problem = await live.eject(mountPoint)
                lines.append("eject \(mountPoint): \(problem ?? "ok") · \(Int(Date().timeIntervalSince(start) * 1000)) ms")
                return problem
            }
            tools.remount = { mountPoint in
                let start = Date()
                let problem = await live.remount(mountPoint)
                lines.append("remount \(mountPoint): \(problem ?? "ok") · \(Int(Date().timeIntervalSince(start) * 1000)) ms")
                return problem
            }
            transfers.shareTools = tools
            transfers.lastCableReconnect = [:]
            let job = TransferJob(kind: .copy, sources: [.local(URL(filePath: "/tmp/blit-cable-live/Pack"))],
                                  destination: URL(filePath: share + "/blit-cable-live-test"), title: "Live", destinationName: "test")
            let label = await transfers.keepSharesOnCable(job)
            transfers.shareTools = .live
            transfers.lastCableReconnect = [:]
            for line in job.log { lines.append("    \(line.text)") }
            let after = await live.connection(share)
            lines.append("after: link \(label ?? "none") · \(after.map { "\($0.interface) to \($0.server)" } ?? "no connection") · mounted at \(share) \(MountInfo.mounted(at: share) != nil)")
            lines.append("done")
        }
    }

    /// `-BlitBusyTest <log> -BlitBusyTestDest <folder on another volume>`: how
    /// the window keeps up during a real copy (a 1.5 GB file and 400 small
    /// ones, both panes showing its folders): the main thread's stalls, how
    /// soon Pause, Resume and Cancel take hold, and a moment for the shell to
    /// sample the process (<log>.sample, then <log>.sampled).
    static func runBusyTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitBusyTest"),
              let destPath = UserDefaults.standard.string(forKey: "BlitBusyTestDest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-busy-test")
            try? fm.removeItem(at: root)
            let pack = root.appendingPathComponent("Pack")
            try? fm.createDirectory(at: pack, withIntermediateDirectories: true)
            let dest = URL(filePath: destPath)
            for name in (try? fm.contentsOfDirectory(atPath: dest.path)) ?? [] { try? fm.removeItem(at: dest.appendingPathComponent(name)) }
            await Task.detached {
                let big = FileManager.default.createFile(atPath: pack.appendingPathComponent("Big.mkv").path, contents: nil)
                if big, let handle = try? FileHandle(forWritingTo: pack.appendingPathComponent("Big.mkv")) {
                    var chunk = Data(count: 8 << 20)
                    chunk.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
                    for _ in 0..<768 { try? handle.write(contentsOf: chunk) }   // 6 GB
                    try? handle.close()
                }
                for i in 0..<400 {
                    FileManager.default.createFile(atPath: pack.appendingPathComponent(String(format: "small-%03d.bin", i)).path,
                                                   contents: Data(repeating: UInt8(i % 251), count: 64 << 10))
                }
            }.value
            guard let tab = PaneTabs.shared.current, let second = tab.second else { return lines.append("no second pane") }
            tab.first.open(.local(root))
            second.open(.local(dest))
            try? await Task.sleep(for: .seconds(1))
            // The main thread's stalls: a 20 ms timer, and how late each tick is.
            var lags: [Double] = []
            var last = Date()
            let ticker = Timer(timeInterval: 0.02, repeats: true) { _ in
                MainActor.assumeIsolated {
                    let now = Date()
                    lags.append(max(0, now.timeIntervalSince(last) - 0.02))
                    last = now
                }
            }
            RunLoop.main.add(ticker, forMode: .common)
            @MainActor func stalls(_ label: String) {
                let sorted = lags.sorted()
                guard !sorted.isEmpty else { return lines.append("\(label): no ticks") }
                let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
                lines.append(String(format: "%@: %d ticks · late p95 %.0f ms · worst %.0f ms · over 100 ms %d", label, sorted.count,
                                    p95 * 1000, (sorted.last ?? 0) * 1000, sorted.filter { $0 > 0.1 }.count))
                lags = []
            }
            // Redraws per second, by view, over `seconds`.
            @MainActor func redraws(_ label: String, seconds: Double) async {
                let before = bodyCounts
                try? await Task.sleep(for: .seconds(seconds))
                let rates = bodyCounts.keys.sorted().map { key in
                    String(format: "%@ %.1f/s", key, Double((bodyCounts[key] ?? 0) - (before[key] ?? 0)) / seconds)
                }
                lines.append("redraws \(label): " + rates.joined(separator: " · "))
            }
            // Switching tabs: the cost of the switch, and until the shown tab's panes have their rows.
            let tabs = PaneTabs.shared
            tabs.newTab()
            try? await Task.sleep(for: .seconds(1))
            tabs.select(index: 0)
            try? await Task.sleep(for: .seconds(1))
            @MainActor func switching(_ label: String) async {
                var costs: [String] = []
                for index in [1, 0, 1, 0] {
                    let start = Date()
                    tabs.select(index: index)
                    let call = Date().timeIntervalSince(start)
                    for _ in 0..<100 where (tabs.current?.first.rows.isEmpty ?? true) { try? await Task.sleep(for: .milliseconds(10)) }
                    try? await Task.sleep(for: .milliseconds(1))
                    costs.append(String(format: "%.0f/%.0f ms", call * 1000, Date().timeIntervalSince(start) * 1000))
                }
                lines.append("switching tabs \(label) (call / rows shown): " + costs.joined(separator: " · "))
            }
            await redraws("idle", seconds: 2)
            await switching("idle")
            stalls("idle")
            if let message = transfers.enqueue([.local(pack)], to: .local(dest), destinationName: dest.lastPathComponent) {
                return lines.append("enqueue: \(message)")
            }
            guard let job = transfers.transferJobs.last else { return lines.append("no job") }
            for _ in 0..<100 where job.status != .running { try? await Task.sleep(for: .milliseconds(100)) }
            @MainActor func timed(_ label: String, _ action: () -> Void, until done: () -> Bool) async {
                let start = Date()
                action()
                for _ in 0..<300 where !done() { try? await Task.sleep(for: .milliseconds(50)) }
                lines.append(String(format: "%@: %@ after %.2f s · %@ · %d%%", label, done() ? "took hold" : "NOT YET", Date().timeIntervalSince(start),
                                    "\(job.status)", Int(job.progress * 100)))
            }
            try? await Task.sleep(for: .seconds(1))
            await timed("pause while copying", { transfers.pause(job) }, until: { job.status == .paused })
            await timed("resume", { transfers.resume(job) }, until: { job.status == .running })
            await redraws("copying", seconds: 2)
            await switching("while copying")
            stalls("copying")
            try? Data().write(to: URL(fileURLWithPath: logPath + ".sample"))
            for _ in 0..<150 where !fm.fileExists(atPath: logPath + ".sampled") { try? await Task.sleep(for: .milliseconds(100)) }
            stalls("copying (while sampled)")
            // The big file's read-back: pause while it's being hashed (it used to wait for all of it).
            for _ in 0..<1200 where job.verifying["Pack/Big.mkv"] == nil && job.status == .running { try? await Task.sleep(for: .milliseconds(25)) }
            try? await Task.sleep(for: .milliseconds(300))
            lines.append("verifying: \(job.verifying.keys.sorted().joined(separator: ", "))")
            await timed("pause while verifying", { transfers.pause(job) }, until: { job.status == .paused })
            await timed("resume", { transfers.resume(job) }, until: { job.status == .running })
            try? await Task.sleep(for: .seconds(1))
            await timed("cancel", { transfers.cancel(job) }, until: { job.status == .cancelled })
            stalls("pause, resume, cancel")
            ticker.invalidate()
            transfers.dismissFinished()
            try? fm.removeItem(at: root)
            for name in (try? fm.contentsOfDirectory(atPath: dest.path)) ?? [] { try? fm.removeItem(at: dest.appendingPathComponent(name)) }
            lines.append("done")
        }
    }

    /// `-BlitQueueClickTest <log> -BlitQueueClickTestDest <folder on another
    /// volume>`: with real clicks (scripts/ui-keys: steps 0–2) on the HUD's
    /// queue list while a 6 GB copy runs and another waits: ‖ PAUSE, then the
    /// first button again (▶ RESUME), then ✕. Then, with a copy running, real
    /// drags (scripts/ui-drag: 0–1) of a file onto a subfolder: one plain, one
    /// with the pane reloading while it hovers (as when a transfer into it
    /// finishes). Logs what each click did and where each file landed.
    static func runQueueClickTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitQueueClickTest"),
              let destPath = UserDefaults.standard.string(forKey: "BlitQueueClickTestDest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-queue-click")
            try? fm.removeItem(at: root)
            let big = root.appendingPathComponent("Big"), small = root.appendingPathComponent("Small"), drop = root.appendingPathComponent("Drop")
            for folder in [big, small, drop.appendingPathComponent("Target")] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
            for name in ["a.bin", "b.bin"] { fm.createFile(atPath: drop.appendingPathComponent(name).path, contents: Data("x".utf8)) }
            for i in 1...3 { fm.createFile(atPath: small.appendingPathComponent("\(i).bin").path, contents: Data(count: 1 << 20)) }
            await Task.detached {
                let file = big.appendingPathComponent("Big.mkv")
                FileManager.default.createFile(atPath: file.path, contents: nil)
                if let handle = try? FileHandle(forWritingTo: file) {
                    var chunk = Data(count: 8 << 20)
                    chunk.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
                    for _ in 0..<768 { try? handle.write(contentsOf: chunk) }   // 6 GB
                    try? handle.close()
                }
            }.value
            let dest = URL(filePath: destPath)
            for name in (try? fm.contentsOfDirectory(atPath: dest.path)) ?? [] { try? fm.removeItem(at: dest.appendingPathComponent(name)) }
            guard let pane = BrowserModel.active, let window = BrowserModel.activeWindow, let content = window.contentView else {
                return lines.append("no browser")
            }
            pane.open(.local(drop))
            PaneTabs.shared.current?.second?.open(.local(dest))
            for _ in 0..<30 where pane.rows.count < 3 { try? await Task.sleep(for: .milliseconds(200)) }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.setFrame(NSRect(x: 120, y: 100, width: 1280, height: 820), display: true)
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            @MainActor func cg(global point: CGPoint) -> [Int] {   // SwiftUI's global space → CG screen
                let screen = window.convertPoint(toScreen: NSPoint(x: point.x, y: content.bounds.height - point.y))
                return [Int(screen.x), Int(screenHeight - screen.y)]
            }
            _ = transfers.enqueue([.local(big)], to: .local(dest), destinationName: dest.lastPathComponent)
            _ = transfers.enqueue([.local(small)], to: .local(dest), destinationName: dest.lastPathComponent)
            transfers.isExpanded = true
            guard let jobA = transfers.transferJobs.first(where: { $0.sources.first == .local(big) }) else { return lines.append("no job") }
            for _ in 0..<100 where jobA.status != .running || queueControls[jobA.id] == nil { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .seconds(1))
            lines.append("A \(jobA.status) · queue rows \(transfers.transferJobs.count) · controls at \(queueControls[jobA.id].map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))×\(Int($0.height))" } ?? "?")")
            // Bring the copy forward with a click on the Target row (it only selects it; ui-keys does it first).
            if let table = firstTable(in: content), let row = pane.rows.firstIndex(where: { $0.name == "Target" }) {
                let rect = table.rect(ofRow: row)
                let screen = window.convertPoint(toScreen: table.convert(NSPoint(x: rect.minX + 90, y: rect.midY), to: nil))
                try? JSONSerialization.data(withJSONObject: [Int(screen.x), Int(screenHeight - screen.y)]).write(to: URL(fileURLWithPath: logPath + ".click"))
            }
            for _ in 0..<100 where !fm.fileExists(atPath: logPath + ".clicked") { try? await Task.sleep(for: .milliseconds(100)) }
            @MainActor func click(_ step: Int, _ label: String, at x: (CGRect) -> CGFloat) async {
                transfers.pinnedJobID = nil
                guard let frame = queueControls[jobA.id] else { return lines.append("\(label): no controls") }
                let point = cg(global: CGPoint(x: x(frame), y: frame.midY))
                try? JSONSerialization.data(withJSONObject: [-1, 0] + point).write(to: URL(fileURLWithPath: logPath + ".keys-\(step)"))
                for _ in 0..<100 where !fm.fileExists(atPath: logPath + ".sent-\(step)") && !fm.fileExists(atPath: logPath + ".aborted") {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                try? await Task.sleep(for: .seconds(2))
                lines.append("click \(label): A \(jobA.status) · stop request \(jobA.stopRequest.map { "\($0)" } ?? "none") · row pinned \(transfers.pinnedJobID == jobA.id)"
                             + (fm.fileExists(atPath: logPath + ".aborted") ? " · ui-keys stopped" : ""))
            }
            await click(0, "‖ PAUSE", at: { $0.minX + 22 })
            await click(1, "first button again (▶ RESUME)", at: { $0.minX + 22 })
            await click(2, "✕", at: { $0.maxX - 8 })
            // Drags with a copy running: a.bin onto Target, then b.bin onto Target while the pane reloads.
            _ = transfers.enqueue([.local(big)], to: .local(dest.appendingPathComponent("again")), destinationName: "again")
            try? fm.createDirectory(at: dest.appendingPathComponent("again"), withIntermediateDirectories: true)
            for _ in 0..<100 where !transfers.transferJobs.contains(where: { $0.status == .running }) { try? await Task.sleep(for: .milliseconds(100)) }
            lines.append("copy running for the drags: \(transfers.transferJobs.contains { $0.status == .running })")
            guard let table = firstTable(in: content) else { return lines.append("no table") }
            @MainActor func rowPoint(_ name: String) -> [Double]? {
                guard let row = pane.rows.firstIndex(where: { $0.name == name }) else { return nil }
                let rect = table.rect(ofRow: row)
                let screen = window.convertPoint(toScreen: table.convert(NSPoint(x: rect.minX + 90, y: rect.midY), to: nil))
                return [screen.x, screenHeight - screen.y]
            }
            for (index, file) in ["a.bin", "b.bin"].enumerated() {
                guard let from = rowPoint(file), let to = rowPoint("Target") else { lines.append("drag \(index): rows not found"); continue }
                UITestHarness.lastDrop = ""
                try? JSONSerialization.data(withJSONObject: from + to).write(to: URL(fileURLWithPath: logPath + ".points-\(index)"))
                for _ in 0..<150 where !fm.fileExists(atPath: logPath + ".hover-\(index)") && !fm.fileExists(atPath: logPath + ".aborted") {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if index == 1 { pane.reload() }   // as when a transfer into this folder finishes
                try? await Task.sleep(for: .milliseconds(300))
                if let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                    content.cacheDisplay(in: content.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: logPath + "-hover-\(index).png"))
                }
                var landed = false
                for _ in 0..<40 {
                    landed = fm.fileExists(atPath: drop.appendingPathComponent("Target/\(file)").path)
                    if landed { break }
                    try? await Task.sleep(for: .milliseconds(150))
                }
                lines.append("drag \(file) onto Target\(index == 1 ? " (pane reloading)" : ""): landed in Target \(landed) · in Drop \(fm.fileExists(atPath: drop.appendingPathComponent(file).path)) · drop: \(UITestHarness.lastDrop.isEmpty ? "none" : UITestHarness.lastDrop)")
                try? await Task.sleep(for: .seconds(1))
            }
            for job in transfers.transferJobs where job.isActive || job.status == .queued || job.status == .paused { transfers.cancel(job) }
            try? await Task.sleep(for: .seconds(1))
            transfers.dismissFinished()
            try? fm.removeItem(at: root)
            for name in (try? fm.contentsOfDirectory(atPath: dest.path)) ?? [] { try? fm.removeItem(at: dest.appendingPathComponent(name)) }
            lines.append("done")
        }
    }

    /// `-BlitFollowTabTest <log>`: the HUD shows the shown tab's transfer
    /// (stand-in jobs, never run): each tab's own, the one dropped onto a
    /// subfolder the tab shows, a fallback for a tab without one, and a
    /// transfer picked in the queue list stays picked only until the tab changes.
    /// Then the tabs' tags: transfers started from a tab show on that tab
    /// only, each tab its own, and only while running; one from a closed tab
    /// goes to the tab showing its folders.
    static func runFollowTabTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitFollowTabTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-follow-tab")
            try? fm.removeItem(at: root)
            let names = ["SSD", "NAS", "Other", "Elsewhere", "Seedbox"]
            for name in names + ["NAS/Movies"] { try? fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
            let folder = { (name: String) in root.appendingPathComponent(name) }
            let tabs = PaneTabs.shared
            guard let first = tabs.current, let firstSecond = first.second else { return lines.append("no second pane") }
            first.first.open(.local(folder("Seedbox")))
            firstSecond.open(.local(folder("SSD")))
            // A new tab gets its second pane a moment later (the window makes it).
            @MainActor func newTab(_ left: String, _ right: String) async {
                tabs.newTab()
                for _ in 0..<50 where tabs.current?.second == nil { try? await Task.sleep(for: .milliseconds(50)) }
                try? await Task.sleep(for: .milliseconds(200))
                tabs.current?.first.open(.local(folder(left)))
                tabs.current?.second?.open(.local(folder(right)))
            }
            await newTab("SSD", "NAS")
            await newTab("Other", "Elsewhere")
            try? await Task.sleep(for: .seconds(1))
            @MainActor func job(_ title: String, from source: String, to destination: String, _ status: TransferJob.Status, startedAgo: Double) -> TransferJob {
                let job = TransferJob(kind: .copy, sources: [.local(folder(source).appendingPathComponent(title))],
                                      destination: folder(destination), title: title, destinationName: destination)
                job.persistent = false
                job.status = status
                job.startedAt = Date().addingTimeInterval(-startedAgo)
                return job
            }
            let download = job("Download", from: "Seedbox", to: "SSD", .running, startedAgo: 30)
            let copy = job("Copy", from: "SSD", to: "NAS/Movies", .running, startedAgo: 10)
            let old = job("Old", from: "Other", to: "Elsewhere", .finished, startedAgo: 600)
            for job in [download, copy, old] { transfers.debugInsert(job) }
            @MainActor func shows(_ label: String, tab index: Int) async {
                tabs.select(index: index)
                try? await Task.sleep(for: .milliseconds(400))
                lines.append("\(label): \(transfers.featured?.title ?? "none") · pinned \(transfers.pinnedJobID.flatMap { id in transfers.jobs.first { $0.id == id }?.title } ?? "none")")
                let shown = Panes.shared.shownLocations
                lines.append("    shown \(shown.map(\.lastComponent)) · two panes \(Panes.shared.twoPanes) · touching "
                             + transfers.jobs.filter { job in shown.contains(where: job.touches) }.map(\.title).joined(separator: ", "))
            }
            await shows("tab 1 (seedbox · SSD)", tab: 0)
            await shows("tab 2 (SSD · NAS, the copy went into NAS/Movies)", tab: 1)
            await shows("tab 3 (other folders, a finished transfer there)", tab: 2)
            old.status = .cancelled
            transfers.debugRemove(old)
            await shows("tab 3 (nothing of its own)", tab: 2)
            transfers.pinnedJobID = copy.id
            lines.append("picked Copy in the queue list on tab 3: \(transfers.featured?.title ?? "none")")
            await shows("then tab 1", tab: 0)
            // What each tab's tag shows (PaneTabBar).
            @MainActor func tags(_ label: String) {
                lines.append("tags, \(label): " + tabs.tabs.enumerated().map { index, tab in
                    let job = transfers.runningTransfer(on: tab.id)
                    return "\(index + 1) " + (job.map { "\($0.title) \(Int(($0.progress * 100).rounded()))%" } ?? "—")
                }.joined(separator: " · "))
            }
            tags("from no tab (by their folders)")
            for job in [download, copy] { transfers.debugRemove(job) }
            @MainActor func from(_ index: Int, _ job: TransferJob, percent: Int64) -> TransferJob {
                job.originTab = tabs.tabs[index].id
                job.totalBytes = 100
                job.resumedBytes = percent
                transfers.debugInsert(job)
                return job
            }
            let one = from(0, job("One", from: "Seedbox", to: "SSD", .running, startedAgo: 40), percent: 42)
            let two = from(1, job("Two", from: "SSD", to: "NAS/Movies", .running, startedAgo: 20), percent: 10)
            let held = from(2, job("Held", from: "Other", to: "Elsewhere", .paused, startedAgo: 300), percent: 70)
            let done = from(2, job("Done", from: "Other", to: "Elsewhere", .finished, startedAgo: 900), percent: 100)
            tags("one each from tabs 1 and 2, tab 3's paused and finished")
            await shows("tab 1 (One started here)", tab: 0)
            await shows("tab 2 (Two started here; One lands in its SSD)", tab: 1)
            await shows("tab 3 (its own paused and finished)", tab: 2)
            let later = from(0, job("Later", from: "Seedbox", to: "SSD", .running, startedAgo: 5), percent: 80)
            tags("a second from tab 1")
            one.status = .finished
            tags("tab 1's first finished")
            let orphan = job("Orphan", from: "Other", to: "Elsewhere", .running, startedAgo: 60)
            orphan.originTab = UUID()   // a tab since closed
            transfers.debugInsert(orphan)
            tags("one from a closed tab")
            for job in [one, two, held, done, later, orphan] { transfers.debugRemove(job) }
            tags("all gone")
            try? fm.removeItem(at: root)
            lines.append("done")
        }
    }

    /// `-BlitReloadDragTest <log> -BlitReloadDragTestDest <folder on another
    /// volume>`: with a 6 GB copy running, real drags (scripts/ui-drag, 0–2)
    /// of a file onto a subfolder in the left pane: plain; with the pane
    /// reloading while it hovers and nothing changed; and with a file
    /// appearing and the transfer-finished refresh arriving mid-drag (it waits
    /// for the mouse button). Logs whether the folder was lit after the
    /// reload, where each file landed, and when the new file showed.
    static func runReloadDragTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitReloadDragTest"),
              let destPath = UserDefaults.standard.string(forKey: "BlitReloadDragTestDest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-reload-drag")
            try? fm.removeItem(at: root)
            let big = root.appendingPathComponent("Big"), drop = root.appendingPathComponent("Drop")
            for folder in [big, drop.appendingPathComponent("Target")] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
            for name in ["a.bin", "b.bin", "c.bin"] { fm.createFile(atPath: drop.appendingPathComponent(name).path, contents: Data("x".utf8)) }
            await Task.detached {
                let file = big.appendingPathComponent("Big.mkv")
                FileManager.default.createFile(atPath: file.path, contents: nil)
                if let handle = try? FileHandle(forWritingTo: file) {
                    var chunk = Data(count: 8 << 20)
                    chunk.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, $0.count) }
                    for _ in 0..<768 { try? handle.write(contentsOf: chunk) }   // 6 GB
                    try? handle.close()
                }
            }.value
            let dest = URL(filePath: destPath)
            for name in (try? fm.contentsOfDirectory(atPath: dest.path)) ?? [] { try? fm.removeItem(at: dest.appendingPathComponent(name)) }
            guard let tab = PaneTabs.shared.current, let right = tab.second, let window = BrowserModel.activeWindow,
                  let content = window.contentView else { return lines.append("no window or second pane") }
            let pane = tab.first
            pane.open(.local(drop))
            right.open(.local(dest))
            for _ in 0..<30 where pane.rows.count < 4 { try? await Task.sleep(for: .milliseconds(200)) }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.setFrame(NSRect(x: 120, y: 100, width: 1280, height: 820), display: true)
            _ = transfers.enqueue([.local(big)], to: .local(dest), destinationName: dest.lastPathComponent)
            // A second copy queued behind it, so a transfer runs through all three drags.
            try? fm.createDirectory(at: dest.appendingPathComponent("again"), withIntermediateDirectories: true)
            _ = transfers.enqueue([.local(big)], to: .local(dest.appendingPathComponent("again")), destinationName: "again")
            for _ in 0..<100 where !transfers.transferJobs.contains(where: { $0.status == .running }) { try? await Task.sleep(for: .milliseconds(100)) }
            try? await Task.sleep(for: .seconds(2.5))   // the HUD opening as the copy starts settles the layout
            try? String(window.windowNumber).write(toFile: logPath + ".wid", atomically: true, encoding: .utf8)
            lines.append("copy running: \(transfers.transferJobs.contains { $0.status == .running }) · rows \(pane.rows.map(\.name))")
            // The left pane's table: the leftmost list in the window.
            let tables = fileLists(in: window)
            guard let table = tables.first else {
                return lines.append("no table")
            }
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            @MainActor func rowPoint(_ name: String) -> [Double]? {
                guard let row = pane.rows.firstIndex(where: { $0.name == name }) else { return nil }
                let rect = table.rect(ofRow: row)
                let screen = window.convertPoint(toScreen: table.convert(NSPoint(x: rect.minX + 90, y: rect.midY), to: nil))
                return [screen.x, screenHeight - screen.y]
            }
            for (index, file) in ["a.bin", "b.bin", "c.bin"].enumerated() {
                guard let from = rowPoint(file), let to = rowPoint("Target") else {
                    lines.append("drag \(file): rows not found · rows \(pane.rows.map(\.name))")
                    continue
                }
                UITestHarness.lastDrop = ""
                UITestHarness.dropTrail = []
                lines.append("before drag \(index + 1): list registered \(FileListRegistry.coordinator(for: pane) != nil) · copy running \(transfers.transferJobs.contains { $0.status == .running })")
                if let row = pane.rows.firstIndex(where: { $0.name == "Target" }) {
                    let rect = table.rect(ofRow: row)
                    let inWindow = table.convert(NSPoint(x: rect.minX + 90, y: rect.midY), to: nil)
                    var chain: [String] = []
                    var view = content.hitTest(content.convert(inWindow, from: nil))
                    while let current = view, chain.count < 8 { chain.append(String(describing: type(of: current))); view = current.superview }
                    lines.append("    hit test over Target: \(chain.joined(separator: " < "))")
                }
                try? JSONSerialization.data(withJSONObject: from + to).write(to: URL(fileURLWithPath: logPath + ".points-\(index)"))
                for _ in 0..<200 where !fm.fileExists(atPath: logPath + ".hover-\(index)") && !fm.fileExists(atPath: logPath + ".aborted") {
                    try? await Task.sleep(for: .milliseconds(25))
                }
                let litBefore = DragHoverRegistry.anyShowing
                switch index {
                case 1:
                    pane.reload()   // nothing changed
                case 2:
                    fm.createFile(atPath: drop.appendingPathComponent("new.bin").path, contents: Data("n".utf8))
                    BrowserModel.reloadWhenIdle([pane])   // as when a transfer into this folder finishes
                default:
                    break
                }
                try? await Task.sleep(for: .milliseconds(300))
                let litAfter = DragHoverRegistry.anyShowing
                    && (FileListRegistry.coordinator(for: pane).map { $0.litRowViews == 1 } ?? true)
                let newShownMidDrag = pane.rows.contains { $0.name == "new.bin" }
                var landed = false
                for _ in 0..<40 {
                    landed = fm.fileExists(atPath: drop.appendingPathComponent("Target/\(file)").path)
                    if landed { break }
                    try? await Task.sleep(for: .milliseconds(150))
                }
                try? await Task.sleep(for: .seconds(1))
                let label = ["plain", "pane reloaded, nothing changed", "new file + transfer-finished refresh"][index]
                lines.append("drag \(file) onto Target (\(label)): lit before \(litBefore) · lit after \(litAfter) · landed in Target \(landed)"
                             + (index == 2 ? " · new.bin listed mid-drag \(newShownMidDrag), after \(pane.rows.contains { $0.name == "new.bin" })" : "")
                             + " · drop: \(UITestHarness.lastDrop.isEmpty ? "none" : UITestHarness.lastDrop)"
                             + " · trail \(UITestHarness.dropTrail.reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } })"
                             + (fm.fileExists(atPath: logPath + ".aborted") ? " · ui-drag stopped" : ""))
            }
            for job in transfers.transferJobs where job.isActive || job.status == .queued { transfers.cancel(job) }
            try? await Task.sleep(for: .seconds(1))
            transfers.dismissFinished()
            try? fm.removeItem(at: root)
            for name in (try? fm.contentsOfDirectory(atPath: dest.path)) ?? [] { try? fm.removeItem(at: dest.appendingPathComponent(name)) }
            lines.append("done")
        }
    }

    /// `-BlitTabSwitchTest <log>`: how long a tab switch keeps the main thread
    /// (two tabs, or `-BlitTabSwitchTabs N`; 300 files in each pane, or
    /// `-BlitTabSwitchFiles N`): 40 switches, each timed until the run loop
    /// has been round twice (the window has drawn), with a pause after the
    /// first ten for the shell to sample the process (<log>.sample, then
    /// <log>.sampled; touch <log>.sampled first to skip it, as a sampler slows
    /// the process). Then the same for making the other pane active and for
    /// resizing the window, and the memory footprint.
    static func runTabSwitchTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitTabSwitchTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-tab-switch")
            try? fm.removeItem(at: root)
            for name in ["A", "B", "C", "D"] {
                let folder = root.appendingPathComponent(name)
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
                let count = UserDefaults.standard.integer(forKey: "BlitTabSwitchFiles")
                for i in 0..<(count > 0 ? count : 300) { fm.createFile(atPath: folder.appendingPathComponent(String(format: "%@-file-%03d.mkv", name, i)).path, contents: Data("x".utf8)) }
            }
            let tabs = PaneTabs.shared
            guard let window = BrowserModel.activeWindow, let first = tabs.current, let firstSecond = first.second else {
                return lines.append("no second pane")
            }
            window.setFrame(NSRect(x: 100, y: 100, width: 1280, height: 800), display: true)
            first.first.open(.local(root.appendingPathComponent("A")))
            firstSecond.open(.local(root.appendingPathComponent("B")))
            // -BlitTabSwitchTabs N: N tabs (2 by default), showing A | B and C | D in turn.
            let tabCount = max(2, UserDefaults.standard.integer(forKey: "BlitTabSwitchTabs"))
            for index in 1..<tabCount {
                tabs.newTab()
                for _ in 0..<50 where tabs.current?.second == nil { try? await Task.sleep(for: .milliseconds(50)) }
                try? await Task.sleep(for: .milliseconds(200))
                tabs.current?.first.open(.local(root.appendingPathComponent(index % 2 == 0 ? "A" : "C")))
                tabs.current?.second?.open(.local(root.appendingPathComponent(index % 2 == 0 ? "B" : "D")))
                try? await Task.sleep(for: .milliseconds(500))
            }
            try? await Task.sleep(for: .seconds(2))
            var times: [Double] = []
            // Until the run loop has been round twice: SwiftUI's update, AppKit's
            // layout and the display commit happen in the first round's observers.
            @MainActor func settled() async {
                await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.async { DispatchQueue.main.async { done.resume() } }
                }
            }
            @MainActor func switches(_ count: Int, select: Bool = true) async {
                for n in 0..<count {
                    let start = CACurrentMediaTime()
                    if select { tabs.select(index: n % tabCount) }
                    await settled()
                    times.append((CACurrentMediaTime() - start) * 1000)
                    try? await Task.sleep(for: .milliseconds(60))
                }
            }
            // The same wait with no switch: what the measuring itself costs.
            await switches(10, select: false)
            let baseline = times.sorted()[5]
            times = []
            tabs.select(index: 0)
            try? await Task.sleep(for: .milliseconds(300))
            let before = bodyCounts
            await switches(10)
            lines.append("redraws per switch: " + bodyCounts.keys.sorted().map { key in
                String(format: "%@ %.1f", key, Double((bodyCounts[key] ?? 0) - (before[key] ?? 0)) / 10)
            }.joined(separator: " · "))
            try? Data().write(to: URL(fileURLWithPath: logPath + ".sample"))
            try? await Task.sleep(for: .milliseconds(300))
            await switches(30)
            for _ in 0..<100 where !fm.fileExists(atPath: logPath + ".sampled") { try? await Task.sleep(for: .milliseconds(100)) }
            let sorted = times.sorted()
            lines.append(String(format: "%d switches · median %.0f ms · p90 %.0f ms · worst %.0f ms · first %.0f ms · no switch %.1f ms",
                                sorted.count, sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.9)], sorted.last ?? 0, times.first ?? 0, baseline))
            lines.append("rows shown: \(tabs.current?.first.rows.count ?? -1) | \(tabs.current?.second?.rows.count ?? -1) · \(tabCount) tabs")
            // Making the other pane the active one (a click on it), as the window does.
            var activations: [Double] = []
            for _ in 0..<20 {
                guard let tab = tabs.current else { break }
                let start = CACurrentMediaTime()
                tab.secondActive.toggle()
                await settled()
                activations.append((CACurrentMediaTime() - start) * 1000)
                try? await Task.sleep(for: .milliseconds(60))
            }
            let activated = activations.sorted()
            lines.append(String(format: "other pane active · median %.1f ms · worst %.1f ms", activated[activated.count / 2], activated.last ?? 0))
            // Resizing the window: every list there is follows it.
            var resizes: [Double] = []
            for n in 0..<12 {
                let start = CACurrentMediaTime()
                window.setFrame(NSRect(x: 100, y: 100, width: n % 2 == 0 ? 1160 : 1280, height: 800), display: true)
                await settled()
                resizes.append((CACurrentMediaTime() - start) * 1000)
                try? await Task.sleep(for: .milliseconds(60))
            }
            let resized = resizes.sorted()
            lines.append(String(format: "resize · median %.0f ms · worst %.0f ms · footprint %.0f MB", resized[resized.count / 2], resized.last ?? 0, footprintMB()))
            // -BlitTabSwitchLayers YES: the layers with backing stores over 1 MB.
            if UserDefaults.standard.bool(forKey: "BlitTabSwitchLayers"), let content = window.contentView {
                var byClass: [String: (count: Int, megabytes: Double)] = [:]
                func add(_ layer: CALayer, owner: String) {
                    if layer.contents != nil {
                        let megabytes = Double(layer.bounds.width * layer.bounds.height * layer.contentsScale * layer.contentsScale * 4) / 1_048_576
                        let key = owner + " / " + String(describing: type(of: layer))
                        byClass[key, default: (0, 0)].count += 1
                        byClass[key, default: (0, 0)].megabytes += megabytes
                    }
                }
                func walkLayers(_ layer: CALayer, owner: String, skip: Set<ObjectIdentifier>) {
                    for sub in layer.sublayers ?? [] where !skip.contains(ObjectIdentifier(sub)) {
                        add(sub, owner: owner + "·sub")
                        walkLayers(sub, owner: owner, skip: skip)
                    }
                }
                func walk(_ view: NSView) {
                    let owner = String(describing: type(of: view)).prefix(40)
                    if let layer = view.layer {
                        add(layer, owner: String(owner))
                        // Sublayers that aren't other views' layers.
                        let viewLayers = Set(view.subviews.compactMap { $0.layer.map(ObjectIdentifier.init) })
                        walkLayers(layer, owner: String(owner), skip: viewLayers)
                    }
                    view.subviews.forEach(walk)
                }
                walk(content)
                let total = byClass.values.reduce(0) { $0 + $1.megabytes }
                lines.append(String(format: "layer contents: %.1f MB in %d layers", total, byClass.values.reduce(0) { $0 + $1.count }))
                for (key, value) in byClass.sorted(by: { $0.value.megabytes > $1.value.megabytes }).prefix(12) {
                    lines.append(String(format: "    %.1f MB · %d × ", value.megabytes, value.count) + key)
                }
            }
            try? fm.removeItem(at: root)
            lines.append("done")
        }
    }

    /// `-BlitTabPressTest <log>`: which tab a press chooses (TabPress, the
    /// tab bar's mouse-down monitor), from presses made up at each tab's spots
    /// and handed to it directly, never sent: the test copy stays in the back.
    static func runTabPressTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitTabPressTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let tabs = PaneTabs.shared
            for _ in 0..<2 {
                tabs.newTab()
                try? await Task.sleep(for: .milliseconds(700))
            }
            tabs.select(index: 0)
            try? await Task.sleep(for: .milliseconds(700))
            guard let window = BrowserModel.activeWindow, let content = window.contentView, tabs.tabs.count == 3 else {
                return lines.append("no window or tabs")
            }
            @MainActor func press(_ label: String, tab index: Int, clickCount: Int = 1, flags: NSEvent.ModifierFlags = [],
                                  at place: (TabPress.Spot) -> CGPoint) {
                guard let spot = TabPress.spots[tabs.tabs[index].id] else { return lines.append("\(label): no spot") }
                let point = place(spot)
                guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: point.x, y: content.bounds.height - point.y),
                                                     modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                     windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                     clickCount: clickCount, pressure: 1) else { return lines.append("\(label): no event") }
                let chosen = TabPress.tab(at: event)
                if let chosen { tabs.select(chosen) }
                let name = chosen.flatMap { id in tabs.tabs.firstIndex { $0.id == id } }.map { "tab \($0 + 1)" } ?? "none"
                lines.append("\(label): \(name) · shown tab \((tabs.selectedIndex ?? -1) + 1)")
            }
            press("tab 2, its name", tab: 1) { CGPoint(x: $0.tab.midX, y: $0.tab.midY) }
            press("tab 3, its right end (the transfer tag)", tab: 2) { CGPoint(x: $0.tab.maxX - 6, y: $0.tab.midY) }
            press("tab 1, its close button", tab: 0) { CGPoint(x: $0.close.midX, y: $0.close.midY) }
            press("tab 1, just right of the close button", tab: 0) { CGPoint(x: $0.close.maxX + 2, y: $0.close.midY) }
            press("tab 1, a double-click's second press", tab: 0, clickCount: 2) { CGPoint(x: $0.tab.midX, y: $0.tab.midY) }
            press("tab 1, ⌃-click", tab: 0, flags: .control) { CGPoint(x: $0.tab.midX, y: $0.tab.midY) }
            press("below tab 1, in the list", tab: 0) { CGPoint(x: $0.tab.midX, y: $0.tab.maxY + 60) }
            press("tab 1, its name", tab: 0) { CGPoint(x: $0.tab.midX + 20, y: $0.tab.midY) }
            lines.append("done")
        }
    }

    /// `-BlitTableMetricsTest <log>`: how the left file list's table is set up
    /// (style, rows, spacing, header, columns, scroll view, a cell's views and
    /// fonts), to copy into the AppKit list and compare the two.
    static func runTableMetricsTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitTableMetricsTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-table-metrics")
            try? fm.removeItem(at: root)
            let left = root.appendingPathComponent("Left"), right = root.appendingPathComponent("Right")
            for folder in [left, right] {
                try? fm.createDirectory(at: folder.appendingPathComponent("Sub"), withIntermediateDirectories: true)
                for name in ["a.mkv", "b.txt"] { fm.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data("x".utf8)) }
                // -BlitTableMetricsFiles N: that many more files.
                for index in 0..<UserDefaults.standard.integer(forKey: "BlitTableMetricsFiles") {
                    fm.createFile(atPath: folder.appendingPathComponent(String(format: "file-%04d.mkv", index)).path, contents: Data("x".utf8))
                }
            }
            guard let window = BrowserModel.activeWindow, let tab = PaneTabs.shared.current, let second = tab.second else {
                return lines.append("no window or second pane")
            }
            window.setFrame(NSRect(x: 100, y: 100, width: 1280, height: 800), display: true)
            tab.first.open(.local(left))
            second.open(.local(right))
            try? await Task.sleep(for: .seconds(2))
            // -BlitTableMetricsScroll YES: scrolled halfway down first.
            if UserDefaults.standard.bool(forKey: "BlitTableMetricsScroll") {
                for case let scroll as NSScrollView in (window.contentView.map { [$0] } ?? []).flatMap({ view -> [NSView] in
                    var all: [NSView] = []
                    func walk(_ v: NSView) { all.append(v); v.subviews.forEach(walk) }
                    walk(view)
                    return all
                }) where (scroll.documentView as? NSTableView)?.headerView != nil {
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: (scroll.documentView?.frame.height ?? 0) / 2))
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
                try? await Task.sleep(for: .seconds(1))
            }
            let tables = fileLists(in: window)
            guard let table = tables.first else {
                return lines.append("no table")
            }
            func f(_ value: CGFloat) -> String { String(format: "%.1f", value) }
            lines.append("table \(type(of: table)) · style \(table.style.rawValue) · effective \(table.effectiveStyle.rawValue) · rows \(table.numberOfRows)")
            lines.append("rowHeight \(f(table.rowHeight)) · automatic \(table.usesAutomaticRowHeights) · row 0 height \(table.numberOfRows > 0 ? f(table.rect(ofRow: 0).height) : "-") · rowSizeStyle \(table.rowSizeStyle.rawValue) · effective \(table.effectiveRowSizeStyle.rawValue)")
            lines.append("intercellSpacing \(f(table.intercellSpacing.width))×\(f(table.intercellSpacing.height)) · grid \(table.gridStyleMask.rawValue) · alternating \(table.usesAlternatingRowBackgroundColors) · background \(table.backgroundColor)")
            lines.append("selection \(table.selectionHighlightStyle.rawValue) · multiple \(table.allowsMultipleSelection) · empty \(table.allowsEmptySelection) · typeSelect \(table.allowsTypeSelect) · reorder \(table.allowsColumnReordering) · resize \(table.allowsColumnResizing) · autoresizing \(table.columnAutoresizingStyle.rawValue) · focusRing \(table.focusRingType.rawValue) · floatsGroupRows \(table.floatsGroupRows)")
            lines.append("verticalMotionCanBeginDrag \(table.verticalMotionCanBeginDrag) · draggingFeedback \(table.draggingDestinationFeedbackStyle.rawValue) · registered \(table.registeredDraggedTypes.map(\.rawValue))")
            if let header = table.headerView {
                lines.append("header \(type(of: header)) · height \(f(header.frame.height))")
            }
            for column in table.tableColumns {
                let cell = column.headerCell
                lines.append("column \(column.identifier.rawValue) “\(column.title)” · width \(f(column.width)) min \(f(column.minWidth)) max \(f(column.maxWidth)) · mask \(column.resizingMask.rawValue) · hidden \(column.isHidden) · sort \(column.sortDescriptorPrototype.map { "\($0.key ?? "-") \($0.ascending)" } ?? "-") · header font \(cell.font.map { "\($0.fontName) \(f($0.pointSize))" } ?? "-") · align \(cell.alignment.rawValue)")
            }
            if let scroll = table.enclosingScrollView {
                lines.append("scroll \(type(of: scroll)) · insets t\(f(scroll.contentInsets.top)) b\(f(scroll.contentInsets.bottom)) · automatic \(scroll.automaticallyAdjustsContentInsets) · scrollers \(scroll.scrollerStyle.rawValue) · autohides \(scroll.autohidesScrollers) · border \(scroll.borderType.rawValue) · drawsBackground \(scroll.drawsBackground) · clip \(type(of: scroll.contentView))")
            }
            if let scroll = table.enclosingScrollView {
                let clip = scroll.contentView
                lines.append("scroll more: hScroller \(scroll.hasHorizontalScroller) · vScroller \(scroll.hasVerticalScroller) · hElastic \(scroll.horizontalScrollElasticity.rawValue) · vElastic \(scroll.verticalScrollElasticity.rawValue) · predominant \(scroll.usesPredominantAxisScrolling) · bg \(scroll.backgroundColor) · clip draws \(clip.drawsBackground) · clip bg \(clip.backgroundColor) · clip insets t\(f(clip.contentInsets.top)) b\(f(clip.contentInsets.bottom)) · automaticClip \(clip.automaticallyAdjustsContentInsets) · scroller insets b\(f(scroll.scrollerInsets.bottom)) · table frame \(table.frame) · clip bounds \(clip.bounds) · wantsLayer \(table.wantsLayer) · scroll wantsLayer \(scroll.wantsLayer)")
            }
            // Layers with their own backing store, and how big (a full-height one costs memory).
            var layers: [String] = []
            func layerWalk(_ view: NSView, _ depth: Int) {
                guard depth < 4 else { return }
                if let layer = view.layer {
                    let px = layer.bounds.width * layer.bounds.height * layer.contentsScale * layer.contentsScale * 4 / 1_048_576
                    layers.append(String(repeating: "  ", count: depth) + "\(type(of: view)) \(type(of: layer)) \(f(layer.bounds.width))×\(f(layer.bounds.height)) contents \(layer.contents != nil) ~\(String(format: "%.1f", px)) MB · drawsAsLayer \(view.wantsUpdateLayer) · policy \(view.layerContentsRedrawPolicy.rawValue)")
                }
                for sub in view.subviews.prefix(6) { layerWalk(sub, depth + 1) }
            }
            if let scroll = table.enclosingScrollView { layerWalk(scroll, 0) }
            lines.append("layers:\n    " + layers.joined(separator: "\n    "))
            if table.numberOfRows > 0, let rowView = table.rowView(atRow: 0, makeIfNecessary: false) {
                lines.append("row view \(type(of: rowView)) · frame \(rowView.frame) · emphasized \(rowView.isEmphasized) · groupRowStyle \(rowView.isGroupRowStyle)")
                for column in 0..<table.numberOfColumns where !table.tableColumns[column].isHidden {
                    guard let cell = table.view(atColumn: column, row: 0, makeIfNecessary: false) else { continue }
                    var chain: [String] = []
                    func walk(_ view: NSView, _ depth: Int) {
                        guard depth < 4, chain.count < 12 else { return }
                        chain.append(String(repeating: "  ", count: depth) + "\(type(of: view)) \(f(view.frame.minX)),\(f(view.frame.minY)) \(f(view.frame.width))×\(f(view.frame.height))")
                        view.subviews.forEach { walk($0, depth + 1) }
                    }
                    walk(cell, 0)
                    lines.append("cell \(table.tableColumns[column].title):\n    " + chain.joined(separator: "\n    "))
                }
            }
            // Each list's rows against its model's, and the folder row's disclosure button.
            var allTables: [NSTableView] = []
            func collectTables(_ view: NSView) {
                if let table = view as? NSTableView, table.headerView != nil { allTables.append(table) }
                view.subviews.forEach(collectTables)
            }
            if let content = window.contentView { collectTables(content) }
            for (index, table) in allTables.enumerated() {
                let model = [tab.first, second][min(index, 1)]
                var buttons: [String] = []
                table.enumerateAvailableRowViews { rowView, row in
                    for case let button as NSButton in (rowView.view(atColumn: 0) as? NSView)?.subviews ?? [] {
                        buttons.append("row \(row) button hidden \(button.isHidden) frame \(button.frame) image \(button.image != nil)")
                    }
                }
                lines.append("table \(index): numberOfRows \(table.numberOfRows) · model rows \(model.rows.count) · \(buttons.filter { $0.contains("hidden false") }.joined(separator: "; "))")
            }
            // A picture of the window: the shell captures it once it sees <log>.wid.
            try? String(window.windowNumber).write(toFile: logPath + ".wid", atomically: true, encoding: .utf8)
            for _ in 0..<100 where !fm.fileExists(atPath: logPath + ".shot") { try? await Task.sleep(for: .milliseconds(100)) }
            try? fm.removeItem(at: root)
            lines.append("done")
        }
    }

    /// `-BlitNativeKeysTest <log>` (two panes): the AppKit
    /// list's keys and focus, sent straight to the lists (no real input): Tab
    /// and ⇧Tab go to the other pane, → and ← open and close a folder in
    /// place, type-select, Return with two rows selected opens the first, and
    /// after a tab switch the shown tab's active list has the keyboard.
    static func runNativeKeysTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitNativeKeysTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-native-keys")
            try? fm.removeItem(at: root)
            let left = root.appendingPathComponent("Left"), right = root.appendingPathComponent("Right")
            for folder in [left.appendingPathComponent("Sub"), left.appendingPathComponent("Tub"), right] {
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            for name in ["Left/b.bin", "Left/c.bin", "Left/Sub/a.bin", "Right/d.bin"] {
                fm.createFile(atPath: root.appendingPathComponent(name).path, contents: Data("x".utf8))
            }
            defer { try? fm.removeItem(at: root) }
            guard let first = PaneTabs.shared.current?.first, let window = BrowserModel.activeWindow else { return lines.append("no window") }
            guard let second = BrowserModel.oppositePane?(first) else { return lines.append("no second pane (showSecondPane off?)") }
            first.open(.local(left))
            second.open(.local(right))
            first.sort(by: .name)
            for _ in 0..<30 where first.rows.count < 4 || second.rows.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            try? await Task.sleep(for: .milliseconds(500))
            guard let leftTable = FileListRegistry.table(for: first), let rightTable = FileListRegistry.table(for: second) else {
                return lines.append("no lists")
            }
            @MainActor func keyboard() -> String {
                let responder = window.firstResponder
                return responder === leftTable ? "left" : responder === rightTable ? "right" : responder.map { "\(type(of: $0))" } ?? "none"
            }
            @MainActor func active() -> String { BrowserModel.active === first ? "left" : BrowserModel.active === second ? "right" : "other" }
            @MainActor func key(_ table: NSTableView, _ code: UInt16, _ characters: String, shift: Bool = false) {
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? [.shift] : [],
                                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                                   context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                                   isARepeat: false, keyCode: code) else { return }
                table.keyDown(with: event)
            }
            func pause(_ seconds: Double = 0.4) async { try? await Task.sleep(for: .seconds(seconds)) }
            lines.append("at launch: keyboard \(keyboard()) · active \(active())")
            first.requestKeyboardFocus()
            await pause()
            lines.append("start: keyboard \(keyboard()) · active \(active())")
            key(leftTable, 48, "\t")
            await pause()
            lines.append("Tab: keyboard \(keyboard()) · active \(active())")
            key(rightTable, 48, "\u{19}", shift: true)
            await pause()
            lines.append("⇧Tab: keyboard \(keyboard()) · active \(active())")
            // → opens a folder in place; ← from the file inside closes it and selects it.
            guard let sub = first.rows.first(where: { $0.name == "Sub" }) else { return lines.append("no Sub · rows \(first.rows.map(\.name))") }
            first.selection = [sub.location]
            await pause()
            key(leftTable, 124, "\u{F703}")
            await pause(0.8)
            lines.append("→: open \(first.expanded.contains(sub.location)) · table rows \(leftTable.numberOfRows) · rows \(first.rows.map(\.name))")
            if let inner = first.rows.first(where: { $0.name == "a.bin" }) { first.selection = [inner.location] }
            await pause()
            key(leftTable, 123, "\u{F702}")
            await pause(0.8)
            lines.append("← inside: open \(first.expanded.contains(sub.location)) · selected \(first.selectedItems.map(\.name)) · table rows \(leftTable.numberOfRows) · table selection \(Array(leftTable.selectedRowIndexes))")
            // Type-select.
            key(leftTable, 8, "c")
            await pause(0.8)
            lines.append("type c: selected \(first.selectedItems.map(\.name))")
            // Return with two folders selected browses into the first.
            if let tub = first.rows.first(where: { $0.name == "Tub" }) { first.selection = [sub.location, tub.location] }
            await pause()
            key(leftTable, 36, "\r")
            await pause(1)
            lines.append("Return on two: in \(first.current?.lastComponent ?? "?") · rows \(first.rows.map(\.name))")
            first.goBack()
            await pause(0.8)
            // Tabs: the new tab's active list takes the keyboard; Tab there; back
            // on the first tab the keyboard is its left list again.
            guard let firstTab = PaneTabs.shared.current?.id else { return lines.append("no tab") }
            // The new tab's pane has no folder for a moment (its list hides):
            // the keyboard waits, then comes back to the list.
            PaneTabs.shared.newTab()
            var seen: [String] = []
            for _ in 0..<20 {
                let now = window.firstResponder.map { "\(type(of: $0))" } ?? "none"
                if seen.last != now { seen.append(now) }
                try? await Task.sleep(for: .milliseconds(50))
            }
            lines.append("after ⌘T the keyboard went: \(seen.joined(separator: " → "))")
            guard let tab = PaneTabs.shared.current, tab.id != firstTab, let newFirst = Optional(tab.first),
                  let newSecond = tab.second, let newLeft = FileListRegistry.table(for: newFirst),
                  let newRight = FileListRegistry.table(for: newSecond) else { return lines.append("no new tab lists") }
            @MainActor func tabKeyboard() -> String {
                window.firstResponder === newLeft ? "left" : window.firstResponder === newRight ? "right" : window.firstResponder.map { "\(type(of: $0))" } ?? "none"
            }
            lines.append("new tab: keyboard \(tabKeyboard()) · active \(BrowserModel.active === newFirst ? "left" : BrowserModel.active === newSecond ? "right" : "other")")
            key(newLeft, 48, "\t")
            await pause()
            lines.append("new tab, Tab: keyboard \(tabKeyboard())")
            PaneTabs.shared.select(firstTab)
            await pause(1)
            lines.append("back on tab 1: keyboard \(keyboard()) · active \(active())")
            PaneTabs.shared.select(tab.id)
            await pause(1)
            lines.append("tab 2 again: keyboard \(tabKeyboard())")
            // A third tab (the tab bar already shows).
            PaneTabs.shared.newTab()
            var third: [String] = []
            for _ in 0..<20 {
                let now = window.firstResponder.map { "\(type(of: $0))" } ?? "none"
                if third.last != now { third.append(now) }
                try? await Task.sleep(for: .milliseconds(50))
            }
            lines.append("third tab: the keyboard went \(third.joined(separator: " → "))")
            if let id = PaneTabs.shared.current?.id, id != tab.id, id != firstTab { PaneTabs.shared.close(id) }
            await pause(0.6)
            PaneTabs.shared.close(tab.id)
            await pause(1)
            lines.append("tab 2 closed: keyboard \(keyboard()) · active \(active())")
            lines.append("done")
        }
    }

    /// `-BlitNativeDropTest <log>` (two panes):
    /// the AppKit list's drag and drop, driven by a stand-in drag (no real
    /// input): what a dragged row puts on the pasteboard, which folder lights
    /// up as it moves (a folder row, the folder holding a file in an expanded
    /// folder, never a folder being dragged; the list otherwise), a folder
    /// selected in the receiving pane taking a drag from the other, and where
    /// the dropped files land.
    static func runNativeDropTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitNativeDropTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-native-drop")
            try? fm.removeItem(at: root)
            let left = root.appendingPathComponent("Left"), right = root.appendingPathComponent("Right")
            for folder in ["Left/Sub", "Left/Other", "Right/Box"] {
                try? fm.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
            }
            for name in ["Left/a.bin", "Left/b.bin", "Left/Sub/inner.bin", "Right/c.bin"] {
                fm.createFile(atPath: root.appendingPathComponent(name).path, contents: Data("x".utf8))
            }
            defer { try? fm.removeItem(at: root) }
            guard let first = PaneTabs.shared.current?.first, let window = BrowserModel.activeWindow else { return lines.append("no window") }
            guard let second = BrowserModel.oppositePane?(first) else { return lines.append("no second pane (showSecondPane off?)") }
            first.open(.local(left))
            second.open(.local(right))
            first.sort(by: .name)
            second.sort(by: .name)
            for _ in 0..<30 where first.rows.count < 4 || second.rows.count < 2 { try? await Task.sleep(for: .milliseconds(200)) }
            if let sub = first.rows.first(where: { $0.name == "Sub" }) { first.setExpanded(sub.location, true) }
            for _ in 0..<30 where first.rows.count < 5 { try? await Task.sleep(for: .milliseconds(200)) }
            try? await Task.sleep(for: .milliseconds(600))
            guard let leftList = FileListRegistry.coordinator(for: first), let rightList = FileListRegistry.coordinator(for: second) else {
                return lines.append("no lists")
            }
            lines.append("left rows \(first.rows.map { String(repeating: "  ", count: $0.depth) + $0.name }) · right rows \(second.rows.map(\.name))")
            var sequence = 1000
            /// The rows' pasteboard items, as a drag of `names` from `list` writes them.
            @MainActor func board(_ names: [String], from list: FileListCoordinator, in model: BrowserModel) -> NSPasteboard {
                model.selection = Set(model.rows.filter { names.contains($0.name) }.map(\.id))
                list.table.selectRowIndexes(IndexSet(model.rows.indices.filter { names.contains(model.rows[$0].name) }), byExtendingSelection: false)
                let board = NSPasteboard(name: NSPasteboard.Name("blit-native-drop-\(sequence)"))
                board.clearContents()
                let writers = model.rows.indices.filter { names.contains(model.rows[$0].name) }
                    .compactMap { list.tableView(list.table, pasteboardWriterForRow: $0) }
                board.writeObjects(writers)
                return board
            }
            @MainActor func point(_ name: String?, in list: FileListCoordinator, model: BrowserModel) -> NSPoint {
                let table = list.table
                guard let name, let row = model.rows.firstIndex(where: { $0.name == name }) else {
                    // Below the last row.
                    let last = table.rect(ofRow: max(0, table.numberOfRows - 1))
                    return table.convert(NSPoint(x: last.minX + 60, y: last.maxY + 40), to: nil)
                }
                let rect = table.rect(ofRow: row)
                return table.convert(NSPoint(x: rect.minX + 60, y: rect.midY), to: nil)
            }
            @MainActor func lit(_ list: FileListCoordinator) -> String {
                let value: String = switch list.dropHover.value {
                case .folder(let folder): folder.lastComponent
                case .list: "the list"
                case nil: "nothing"
                }
                return "\(value) (rows lit \(list.litRowViews), outline \(!list.listOutline.isHidden))"
            }
            // 1. What a dragged row carries.
            let pasteboard = board(["a.bin"], from: leftList, in: first)
            lines.append("a.bin's pasteboard: \(pasteboard.pasteboardItems?.map { $0.types.map(\.rawValue) } ?? [])")
            // Two rows: the first row's payload holds both, the other its own; read together, both.
            sequence += 1
            let both = board(["a.bin", "b.bin"], from: leftList, in: first)
            let payloads = both.pasteboardItems?.compactMap { item in
                item.data(forType: .blitLocations).flatMap { try? JSONDecoder().decode(TransferPayload.self, from: $0) }
            } ?? []
            lines.append("a.bin + b.bin: payloads \(payloads.map { $0.locations.map(\.lastComponent) }) · read as \(DropReader.locations(on: both).map(\.lastComponent))")
            // 2. Hovering a drag of a.bin over the left list.
            sequence += 1
            var drag = StandInDrag(pasteboard: pasteboard, sequence: sequence, window: window)
            leftList.dragEntered(drag)
            /// A picture of the left list alone (only this test's files show).
            @MainActor func picture(_ suffix: String) {
                let view = leftList.scrollView
                guard UserDefaults.standard.bool(forKey: "BlitNativeDropPictures"),
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: logPath + "-\(suffix).png"))
            }
            for name in ["Other", "inner.bin", "b.bin", nil] as [String?] {
                drag.location = point(name, in: leftList, model: first)
                _ = leftList.tableView(leftList.table, validateDrop: drag, proposedRow: -1, proposedDropOperation: .on)
                lines.append("a.bin over \(name ?? "empty space"): lights \(lit(leftList))")
                if name == "Other" || name == "b.bin" { picture(name == "Other" ? "folder" : "list") }
            }
            // Spring loading: resting on the closed folder Other opens it in place.
            // AppKit keeps sending updates while a drag rests (and the button is
            // down; with none, the highlight's watchdog clears it in 0.5 s).
            drag.location = point("Other", in: leftList, model: first)
            _ = leftList.tableView(leftList.table, validateDrop: drag, proposedRow: -1, proposedDropOperation: .on)
            let opened = first.rows.first { $0.name == "Other" }.map { first.expanded.contains($0.location) } ?? false
            for _ in 0..<10 {
                try? await Task.sleep(for: .milliseconds(100))
                _ = leftList.tableView(leftList.table, validateDrop: drag, proposedRow: -1, proposedDropOperation: .on)
            }
            let afterRest = first.rows.first { $0.name == "Other" }.map { first.expanded.contains($0.location) } ?? false
            lines.append("resting on Other: open at once \(opened) · after a moment \(afterRest)")
            if let other = first.rows.first(where: { $0.name == "Other" }) { first.setExpanded(other.location, false) }
            leftList.dragExited()
            lines.append("after it left: lights \(lit(leftList))")
            // 3. Dragging Sub: Sub and the file inside it don't take it.
            sequence += 1
            drag = StandInDrag(pasteboard: board(["Sub"], from: leftList, in: first), sequence: sequence, window: window)
            leftList.dragEntered(drag)
            for name in ["Sub", "inner.bin", "Other"] {
                drag.location = point(name, in: leftList, model: first)
                _ = leftList.tableView(leftList.table, validateDrop: drag, proposedRow: -1, proposedDropOperation: .on)
                lines.append("Sub over \(name): lights \(lit(leftList))")
            }
            leftList.dragExited()
            // 4. a.bin onto Box in the right pane, Box selected there.
            second.selection = Set(second.rows.filter { $0.name == "Box" }.map(\.id))
            try? await Task.sleep(for: .milliseconds(300))
            sequence += 1
            drag = StandInDrag(pasteboard: board(["a.bin"], from: leftList, in: first), sequence: sequence, window: window)
            rightList.dragEntered(drag)
            drag.location = point("Box", in: rightList, model: second)
            _ = rightList.tableView(rightList.table, validateDrop: drag, proposedRow: -1, proposedDropOperation: .on)
            lines.append("a.bin over Box (selected in the right pane): lights \(lit(rightList))")
            let accepted = rightList.tableView(rightList.table, acceptDrop: drag, row: -1, dropOperation: .on)
            lines.append("dropped: accepted \(accepted) · lights \(lit(rightList)) · \(lastDrop)")
            // 5. b.bin onto the right list's empty space.
            sequence += 1
            drag = StandInDrag(pasteboard: board(["b.bin"], from: leftList, in: first), sequence: sequence, window: window)
            rightList.dragEntered(drag)
            drag.location = point(nil, in: rightList, model: second)
            _ = rightList.tableView(rightList.table, validateDrop: drag, proposedRow: -1, proposedDropOperation: .on)
            lines.append("b.bin over the right list's empty space: lights \(lit(rightList))")
            _ = rightList.tableView(rightList.table, acceptDrop: drag, row: -1, dropOperation: .on)
            for _ in 0..<20 where !fm.fileExists(atPath: right.appendingPathComponent("b.bin").path) { try? await Task.sleep(for: .milliseconds(150)) }
            try? await Task.sleep(for: .milliseconds(500))
            func contents(_ url: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }
            lines.append("on disk: Left \(contents(left)) · Right \(contents(right)) · Right/Box \(contents(right.appendingPathComponent("Box")))")
            // 6. With the full HUD open (a stand-in transfer running), a drag
            // over a row still finds the list: the view under the pointer, and
            // the first one up from it that takes Blit's drags.
            /// The deepest view under `point` (in `view`'s superview) registered
            /// for Blit's drags, front to back, as AppKit picks a drag's target.
            @MainActor func dragTaker(_ view: NSView, _ point: NSPoint) -> NSView? {
                guard !view.isHidden, view.frame.contains(point) else { return nil }
                let local = view.superview.map { view.convert(point, from: $0) } ?? point
                for sub in view.subviews.reversed() { if let found = dragTaker(sub, local) { return found } }
                return view.registeredDraggedTypes.contains(.blitLocations) ? view : nil
            }
            @MainActor func probe(_ label: String) {
                guard let content = window.contentView, let frame = content.superview else { return }
                for name in ["Other", "inner.bin"] {
                    let inWindow = point(name, in: leftList, model: first)
                    let hit = content.hitTest(content.convert(inWindow, from: nil))
                    let taker = dragTaker(frame, frame.convert(inWindow, from: nil))
                    lines.append("\(label), over \(name): hit test \(hit.map { String(describing: type(of: $0)).prefix(40) } ?? "nothing") · the registered view there \(taker.map { String(describing: type(of: $0)).prefix(40) } ?? "none")")
                }
            }
            /// Whether a click (posted to this copy: the pointer never moves) on
            /// Other's date reaches the left list.
            @MainActor func clickReaches() async -> Bool {
                leftList.pressedOffName = false
                guard let row = first.rows.firstIndex(where: { $0.name == "Other" }) else { return false }
                let column = leftList.table.column(withIdentifier: FileColumn.modified.identifier)
                let rect = leftList.table.frameOfCell(atColumn: max(column, 0), row: row)
                let at = leftList.table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                        NSApp.postEvent(event, atStart: false)
                    }
                    try? await Task.sleep(for: .milliseconds(80))
                }
                try? await Task.sleep(for: .milliseconds(300))
                return leftList.pressedOffName
            }
            lines.append("HUD closed: a click on a row reaches the list \(await clickReaches())")
            probe("HUD closed")
            let job = TransferJob(kind: .copy, sources: [.local(root.appendingPathComponent("x.bin"))], destination: right,
                                  title: "x.bin", destinationName: "Right")
            job.persistent = false
            job.status = .running
            transfers.debugInsert(job)
            transfers.isExpanded = true
            try? await Task.sleep(for: .seconds(1.5))
            probe("HUD open (\(transfers.isExpanded))")
            lines.append("HUD open: a click on a row reaches the list \(await clickReaches())")
            transfers.isExpanded = false
            transfers.debugRemove(job)
            lines.append("done")
        }
    }

    /// `-BlitNativeHardeningTest <log>` (two panes): the AppKit list through
    /// the awkward moments, with no real input: a tab switch mid-rename (it saves), the full HUD opening
    /// mid-rename (it carries on), a tab switch mid-drag (the folder stops
    /// being lit), what VoiceOver reads for a row, and a 10,000-file folder
    /// (how long it takes to show, to switch tabs to and from, and to scroll).
    static func runNativeHardeningTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitNativeHardeningTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-native-hardening")
            try? fm.removeItem(at: root)
            let left = root.appendingPathComponent("Left"), big = root.appendingPathComponent("Big")
            for folder in [left.appendingPathComponent("Folder"), big] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
            for name in ["one.txt", "two.txt"] { fm.createFile(atPath: left.appendingPathComponent(name).path, contents: Data("x".utf8)) }
            defer { try? fm.removeItem(at: root) }
            guard let first = PaneTabs.shared.current?.first, let window = BrowserModel.activeWindow,
                  let firstTab = PaneTabs.shared.current?.id else { return lines.append("no window") }
            first.open(.local(left))
            first.sort(by: .name)
            for _ in 0..<30 where first.rows.count < 3 { try? await Task.sleep(for: .milliseconds(200)) }
            try? await Task.sleep(for: .milliseconds(500))
            guard let list = FileListRegistry.coordinator(for: first) else { return lines.append("no list") }
            func contents(_ url: URL) -> [String] { ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).sorted() }
            @MainActor func pause(_ seconds: Double = 0.5) async { try? await Task.sleep(for: .seconds(seconds)) }
            @MainActor func editor() -> NSTextView? { window.firstResponder as? NSTextView }

            // 1. A tab switch mid-rename saves the name.
            guard let one = first.rows.first(where: { $0.name == "one.txt" }) else { return lines.append("no one.txt") }
            first.beginRename(one)
            await pause()
            if let editor = editor() {
                editor.selectAll(nil)
                editor.insertText("uno.txt", replacementRange: editor.selectedRange())
            }
            lines.append("renaming one.txt: field \(list.renameField != nil) · editor \(editor() != nil)")
            // A click in the field goes to the field (the table takes clicks on its rows' plain views).
            if let field = list.renameField {
                let inTable = field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: list.table)
                let hit = list.table.hitTest(list.table.convert(inTable, to: list.table.superview))
                lines.append("a click in the field goes to \(hit.map { $0 === field || $0 is NSText ? "the field" : "\(type(of: $0))" } ?? "nothing")")
            }
            PaneTabs.shared.newTab()
            await pause(1)
            lines.append("after ⌘T mid-rename: field \(list.renameField != nil) · renaming \(first.renaming != nil) · on disk \(contents(left))")
            guard let secondTab = PaneTabs.shared.current?.id, secondTab != firstTab else { return lines.append("no new tab") }
            PaneTabs.shared.select(firstTab)
            await pause(1)
            lines.append("back on tab 1: field \(list.renameField != nil) · rows \(first.rows.map(\.name)) · keyboard on the list \(window.firstResponder === list.table)")

            // 2. The full HUD opening mid-rename: editing carries on, Return saves.
            guard let two = first.rows.first(where: { $0.name == "two.txt" }) else { return lines.append("no two.txt") }
            first.beginRename(two)
            await pause()
            let job = TransferJob(kind: .copy, sources: [.local(root.appendingPathComponent("x.bin"))], destination: left,
                                  title: "x.bin", destinationName: "Left")
            job.persistent = false
            job.status = .running
            transfers.debugInsert(job)
            transfers.isExpanded = true
            await pause(1.2)
            lines.append("HUD open mid-rename: field \(list.renameField != nil) · editor \(editor() != nil) · renaming \(first.renaming != nil)")
            if let editor = editor() {
                editor.selectAll(nil)
                editor.insertText("dos.txt", replacementRange: editor.selectedRange())
                editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            }
            await pause(1)
            lines.append("after Return: field \(list.renameField != nil) · on disk \(contents(left)) · keyboard on the list \(window.firstResponder === list.table)")
            transfers.isExpanded = false
            transfers.debugRemove(job)
            await pause(0.6)

            // 3. A tab switch mid-drag: the folder stops being lit, here and there.
            let board = NSPasteboard(name: NSPasteboard.Name("blit-native-hardening"))
            board.clearContents()
            if let row = first.rows.firstIndex(where: { $0.name == "uno.txt" }),
               let writer = list.tableView(list.table, pasteboardWriterForRow: row) { board.writeObjects([writer]) }
            let drag = StandInDrag(pasteboard: board, sequence: 77, window: window)
            if let row = first.rows.firstIndex(where: { $0.name == "Folder" }) {
                let rect = list.table.rect(ofRow: row)
                drag.location = list.table.convert(NSPoint(x: rect.minX + 60, y: rect.midY), to: nil)
            }
            list.dragEntered(drag)
            _ = list.tableView(list.table, validateDrop: drag, proposedRow: -1, proposedDropOperation: .on)
            lines.append("hovering Folder: rows lit \(list.litRowViews)")
            PaneTabs.shared.select(secondTab)
            await pause(1)
            lines.append("tab 2 mid-drag: rows lit \(list.litRowViews) · outline \(!list.listOutline.isHidden) · hover \(list.dropHover.value == nil ? "none" : "some")")
            PaneTabs.shared.select(firstTab)
            await pause(1)
            lines.append("back on tab 1: rows lit \(list.litRowViews)")
            PaneTabs.shared.close(secondTab)
            await pause(0.6)

            // 4. What VoiceOver reads for each column of the first rows.
            for row in 0..<min(2, list.table.numberOfRows) {
                var parts: [String] = []
                for column in 0..<list.table.numberOfColumns where !list.table.tableColumns[column].isHidden {
                    let cell = list.table.view(atColumn: column, row: row, makeIfNecessary: false)
                    parts.append("\(list.table.tableColumns[column].title): \(cell?.accessibilityRole()?.rawValue ?? "-") “\(cell?.accessibilityLabel() ?? "")”")
                }
                lines.append("VoiceOver row \(row): " + parts.joined(separator: " · "))
            }
            lines.append("VoiceOver rows: \(list.table.accessibilityRows()?.count ?? -1) of \(list.table.numberOfRows)")
            // A picture of the list alone with its first row selected as in the
            // key window (blue, white text), with -BlitNativeHardeningPictures.
            if UserDefaults.standard.bool(forKey: "BlitNativeHardeningPictures") {
                list.table.selectRowIndexes([0], byExtendingSelection: false)
                list.table.enumerateAvailableRowViews { rowView, _ in rowView.isEmphasized = true }
                await pause(0.3)
                let view = list.scrollView
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: logPath + "-selected.png"))
                }
                // The same in light mode, with Folder lit as a drop target.
                window.appearance = NSAppearance(named: .aqua)
                let lightDrag = StandInDrag(pasteboard: board, sequence: 78, window: window)
                if let row = first.rows.firstIndex(where: { $0.name == "Folder" }) {
                    let rect = list.table.rect(ofRow: row)
                    lightDrag.location = list.table.convert(NSPoint(x: rect.minX + 60, y: rect.midY), to: nil)
                }
                list.dragEntered(lightDrag)
                _ = list.tableView(list.table, validateDrop: lightDrag, proposedRow: -1, proposedDropOperation: .on)
                await pause(0.3)
                if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: logPath + "-light.png"))
                }
                list.dragExited()
                window.appearance = nil
                list.table.enumerateAvailableRowViews { rowView, _ in rowView.isEmphasized = false }
            }

            // 5. A 10,000-file folder.
            for index in 0..<10_000 { fm.createFile(atPath: big.appendingPathComponent(String(format: "file-%05d.bin", index)).path, contents: nil) }
            var start = CACurrentMediaTime()
            first.open(.local(big))
            for _ in 0..<300 where list.table.numberOfRows < 10_000 { try? await Task.sleep(for: .milliseconds(20)) }
            lines.append("10,000 files listed in \(Int((CACurrentMediaTime() - start) * 1000)) ms (rows \(list.table.numberOfRows))")
            await pause(1)
            @MainActor func settled() async {
                await withCheckedContinuation { done in DispatchQueue.main.async { DispatchQueue.main.async { done.resume() } } }
            }
            PaneTabs.shared.newTab()
            await pause(1.5)
            guard let bigTab = Optional(firstTab), let smallTab = PaneTabs.shared.current?.id, smallTab != bigTab else { return lines.append("no tab") }
            var switches: [Int] = []
            for index in 0..<6 {
                start = CACurrentMediaTime()
                PaneTabs.shared.select(index.isMultiple(of: 2) ? bigTab : smallTab)
                await settled()
                switches.append(Int((CACurrentMediaTime() - start) * 1000))
                await pause(0.4)
            }
            lines.append("switches to and from the 10,000-file tab: \(switches.map { "\($0) ms" }.joined(separator: ", "))")
            PaneTabs.shared.select(bigTab)
            await pause(0.8)
            start = CACurrentMediaTime()
            list.table.scrollRowToVisible(9_999)
            await settled()
            lines.append("scroll to the last row: \(Int((CACurrentMediaTime() - start) * 1000)) ms · last visible row \(list.table.rows(in: list.table.visibleRect).upperBound - 1)")
            lines.append("footprint \(footprintMB()) MB")
            PaneTabs.shared.close(smallTab)
            first.open(.local(left))
            await pause(0.8)

            // 5b. New Folder with Selection from the list: the folder shows up
            // selected, with its name being edited; one ⌘Z puts things back.
            // (The File menu has it too, ⌃⌘N; it acts only in the key window.)
            if let item = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { $0.title == "File" })?
                .items.first(where: { $0.title.hasPrefix("New Folder with Selection") }) {
                let keys = (item.keyEquivalentModifierMask.contains(.control) ? "⌃" : "") + (item.keyEquivalentModifierMask.contains(.command) ? "⌘" : "")
                lines.append("File menu: “\(item.title)” \(keys)\(item.keyEquivalent.uppercased())")
            } else {
                lines.append("File menu: no New Folder with Selection")
            }
            first.newFolder(with: first.rows.filter { ["dos.txt", "uno.txt"].contains($0.name) })
            await pause(1.5)
            lines.append("new folder with selection: on disk \(contents(left)) · inside \(contents(left.appendingPathComponent("New Folder With Items"))) · selected \(first.selectedItems.map(\.name)) · renaming \(first.renaming?.lastComponent ?? "none") · field \(list.renameField != nil)")
            first.cancelRename()
            await pause(0.4)
            first.operations.undoManager?.undo()
            await pause(1.2)
            lines.append("after ⌘Z: on disk \(contents(left)) · rows \(first.rows.map(\.name))")

            // 6a. The window made wide, then narrow: each list's table keeps to
            // its visible width (wider would scroll sideways into empty space).
            @MainActor func widths() -> String {
                fileLists(in: window).map { table in
                    "table \(Int(table.frame.width)) · clip \(Int(table.enclosingScrollView?.contentView.bounds.width ?? 0)) · columns \(Int(table.tableColumns.filter { !$0.isHidden }.reduce(0) { $0 + $1.width }))"
                }.joined(separator: " | ")
            }
            let frame = window.frame
            window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: 1500, height: frame.height), display: true)
            await pause(1)
            lines.append("1500 wide: \(widths())")
            window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: 1100, height: frame.height), display: true)
            await pause(1)
            lines.append("then 1100 wide: \(widths())")
            window.setFrame(frame, display: true)
            await pause(0.6)

            // 6. The window closed and opened again (File › New Tab, as ⌘T with
            // no window): the lists go with it and come back, with the keyboard.
            // A name being edited when the window closes is saved.
            if let uno = first.rows.first(where: { $0.name == "uno.txt" }) { first.beginRename(uno) }
            await pause(0.6)
            if let editor = editor() {
                editor.selectAll(nil)
                editor.insertText("un.txt", replacementRange: editor.selectedRange())
            }
            window.performClose(nil)
            await pause(1.5)
            lines.append("closed mid-rename: on disk \(contents(left)) · renaming \(first.renaming != nil)")
            lines.append("window closed: visible \(window.isVisible) · windows shown \(NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.count) · the list detached \(list.model == nil) · in a window \(list.table.window != nil) · registered \(FileListRegistry.coordinator(for: first) != nil)")
            if let item = NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { $0.title == "File" })?.items.first(where: { $0.title == "New Tab" }),
               let menu = item.menu {
                menu.performActionForItem(at: menu.index(of: item))
            }
            await pause(2)
            let reopened = BrowserModel.activeWindow
            let newList = FileListRegistry.coordinator(for: first)
            lines.append("reopened: window \(reopened != nil && reopened !== window) · windows shown \(NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.count) · list \(newList != nil) · rows \(newList?.table.numberOfRows ?? -1) · keyboard on the list \(newList.map { reopened?.firstResponder === $0.table } ?? false) · a new list \(newList !== list) · the old one detached \(list.model == nil)")
            lines.append("done")
        }
    }

    /// `-BlitRenameScrollTest <log>`: renaming rows at different places in a
    /// long list (in view, at the bottom edge under the path bar, just below
    /// it, far down): the field must show and keep the keyboard.
    static func runRenameScrollTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitRenameScrollTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-rename-scroll")
            try? fm.removeItem(at: root)
            try? fm.createDirectory(at: root, withIntermediateDirectories: true)
            for index in 0..<80 { fm.createFile(atPath: root.appendingPathComponent(String(format: "file-%02d.txt", index)).path, contents: nil) }
            defer { try? fm.removeItem(at: root) }
            guard let model = PaneTabs.shared.current?.first, let window = BrowserModel.activeWindow else { return lines.append("no window") }
            model.open(.local(root))
            model.sort(by: .name)
            for _ in 0..<30 where model.rows.count < 80 { try? await Task.sleep(for: .milliseconds(200)) }
            try? await Task.sleep(for: .milliseconds(600))
            guard let list = FileListRegistry.coordinator(for: model) else { return lines.append("no list") }
            let table = list.table
            let visible = table.rows(in: table.visibleRect)
            let inset = table.enclosingScrollView?.contentInsets.bottom ?? 0
            lines.append("rows in view \(visible.location)…\(visible.location + visible.length - 1) · path bar inset \(Int(inset))")
            let last = visible.location + visible.length - 1
            for (label, row) in [("in view", visible.location + 3), ("last in view", last), ("just below", last + 1),
                                 ("far below", 75), ("back near the top", 2)] {
                guard model.rows.indices.contains(row) else { continue }
                model.beginRename(model.rows[row])
                try? await Task.sleep(for: .seconds(1))
                let editing = (window.firstResponder as? NSText)?.delegate === list.renameField && list.renameField != nil
                let inWindow = list.renameField?.window != nil
                lines.append("\(label) (row \(row)): field \(list.renameField != nil) · in the window \(inWindow) · keyboard in it \(editing) · renaming \(model.renaming != nil)")
                model.cancelRename()
                try? await Task.sleep(for: .milliseconds(500))
            }
            // Renaming while the folder reloads (a transfer finishing into it),
            // newest first: a new file comes in at the top; the folder being
            // renamed gets something new inside (and moves to the top).
            try? fm.createDirectory(at: root.appendingPathComponent("Pack"), withIntermediateDirectories: true)
            model.sort(by: .modified)
            model.reload()
            try? await Task.sleep(for: .seconds(1.2))
            @MainActor func state() -> String {
                let editing = (window.firstResponder as? NSText)?.delegate === list.renameField && list.renameField != nil
                let fieldRow = list.renameField.map { list.table.row(for: $0) } ?? -1
                let itemRow = model.renaming.flatMap { location in model.rows.firstIndex { $0.location == location } } ?? -1
                return "field \(list.renameField != nil) · keyboard in it \(editing) · renaming \(model.renaming?.lastComponent ?? "none") · field on row \(fieldRow), item on row \(itemRow)"
            }
            var counter = 0
            for (label, name) in [("a file mid-list", "file-40.txt"), ("a file near the bottom", "file-05.txt"), ("the folder Pack", "Pack")] {
                guard let item = model.rows.first(where: { $0.name == name }) else { lines.append("no \(name)"); continue }
                if let row = model.rows.firstIndex(of: item) { list.table.scrollRowToVisible(row) }
                try? await Task.sleep(for: .milliseconds(300))
                model.beginRename(item)
                try? await Task.sleep(for: .seconds(1))
                lines.append("renaming \(label): \(state())")
                counter += 1
                fm.createFile(atPath: root.appendingPathComponent("new-\(counter).txt").path, contents: nil)
                if name == "Pack" { fm.createFile(atPath: root.appendingPathComponent("Pack/inside.txt").path, contents: nil) }
                BrowserModel.reloadWhenIdle([model])
                try? await Task.sleep(for: .seconds(1.5))
                lines.append("  after a reload: \(state())")
                model.cancelRename()
                try? await Task.sleep(for: .milliseconds(500))
                lines.append("  once it ends: the list shows the new files \(list.table.numberOfRows == model.rows.count) · \(name) on row \(model.rows.firstIndex { $0.name == name } ?? -1) (table: \((0..<list.table.numberOfRows).first { (list.table.view(atColumn: 0, row: $0, makeIfNecessary: false) as? NameCellView)?.accessibilityLabel()?.hasPrefix(name) == true } ?? -1))")
            }
            lines.append("done")
        }
    }

    /// `-BlitNewSinceTest <log>`: new since the last visit. A folder is left
    /// and a file appears in it; back there, that file has the mark and the
    /// others don't. A file renamed here, or a new folder made here, isn't new.
    static func runNewSinceTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitNewSinceTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-new-since")
            try? fm.removeItem(at: root)
            let watched = root.appendingPathComponent("Downloads"), elsewhere = root.appendingPathComponent("Elsewhere")
            for folder in [watched, elsewhere] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
            for name in ["old-1.mkv", "old-2.mkv"] { fm.createFile(atPath: watched.appendingPathComponent(name).path, contents: nil) }
            defer { try? fm.removeItem(at: root) }
            guard let model = PaneTabs.shared.current?.first else { return lines.append("no pane") }
            @MainActor func marks() -> String {
                let list = FileListRegistry.table(for: model)
                return model.rows.map { item in
                    let cell = list.flatMap { table in model.rows.firstIndex(of: item).flatMap { table.view(atColumn: 0, row: $0, makeIfNecessary: false) } }
                    return "\(item.name)\(model.isNew(item) ? " (new)" : "")\((cell?.accessibilityLabel() ?? "").contains("New") ? " [dot]" : "")"
                }.joined(separator: " · ")
            }
            @MainActor func visit(_ url: URL) async {
                model.open(.local(url))
                for _ in 0..<20 where model.current?.localURL?.lastPathComponent != url.lastPathComponent || model.items.isEmpty && url == watched {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                try? await Task.sleep(for: .milliseconds(700))
            }
            await visit(watched)
            lines.append("first visit: \(marks())")
            await visit(elsewhere)
            fm.createFile(atPath: watched.appendingPathComponent("fresh.mkv").path, contents: nil)
            await visit(watched)
            lines.append("back again: \(marks())")
            if let old = model.rows.first(where: { $0.name == "old-1.mkv" }) {
                model.beginRename(old)
                try? await Task.sleep(for: .milliseconds(500))
                model.commitRename(old, to: "renamed.mkv")
                try? await Task.sleep(for: .milliseconds(1200))
            }
            model.newFolder()
            try? await Task.sleep(for: .milliseconds(1200))
            model.cancelRename()
            try? await Task.sleep(for: .milliseconds(500))
            lines.append("after a rename and a new folder here: \(marks())")
            await visit(elsewhere)
            await visit(watched)
            lines.append("the visit after: \(marks())")
            lines.append("done")
        }
    }

    /// `-BlitFinishTest <log>`: the finish moment. Which queues earn it, then
    /// the flourish over the strip of a finished stand-in transfer: drawn
    /// while it plays, nothing drawn once it's over. <log>.wid-N (N = 1, 2)
    /// has the window mid-sweep, for pictures.
    static func runFinishTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitFinishTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let now = Date()
            func batch(_ bytes: Int64, minutes: Double, failed: Int = 0, sizeOnly: Int = 0, unverified: Int = 0) -> TransferManager.Batch {
                TransferManager.Batch(jobs: 1, bytes: bytes, failed: failed, sizeOnly: sizeOnly, unverified: unverified,
                                      started: now.addingTimeInterval(-minutes * 60))
            }
            let cases: [(String, TransferManager.Batch, Bool)] = [
                ("1 GB in 30 s", batch(1_000_000_000, minutes: 0.5), true),
                ("12 GB in 1 min", batch(12_000_000_000, minutes: 1), true),
                ("2 GB in 3 min", batch(2_000_000_000, minutes: 3), true),
                ("12 GB, 1 failed", batch(12_000_000_000, minutes: 5, failed: 1), true),
                ("12 GB, 1 size only", batch(12_000_000_000, minutes: 5, sizeOnly: 1), true),
                ("12 GB, verification off", batch(12_000_000_000, minutes: 5, unverified: 3), true),
                ("12 GB, not all hash-verified", batch(12_000_000_000, minutes: 5), false),
            ]
            for (label, batch, verified) in cases {
                lines.append("\(label): \(TransferManager.celebrates(batch, verified: verified, now: now) ? "flourish" : "nothing")")
            }
            let job = TransferJob(kind: .copy, sources: [.local(URL(fileURLWithPath: "/tmp/blit-finish/Pack"))],
                                  destination: URL(fileURLWithPath: "/tmp/blit-finish-dest"), title: "Pack", destinationName: "NAS")
            job.persistent = false
            job.status = .finished
            job.startedAt = now.addingTimeInterval(-600)
            job.finishedAt = now
            transfers.debugInsert(job)
            defer { transfers.debugRemove(job) }
            try? await Task.sleep(for: .seconds(1))
            let before = bodyCounts["FinishFlourish", default: 0]
            transfers.debugFinishMoment()
            for frame in 1...2 {
                try? await Task.sleep(for: .milliseconds(frame == 1 ? 350 : 300))
                if let window = BrowserModel.activeWindow {
                    try? String(window.windowNumber).write(toFile: logPath + ".wid-\(frame)", atomically: true, encoding: .utf8)
                    for _ in 0..<20 where !FileManager.default.fileExists(atPath: logPath + ".shot-\(frame)") {
                        try? await Task.sleep(for: .milliseconds(25))
                    }
                }
            }
            try? await Task.sleep(for: .seconds(1.5))
            let during = bodyCounts["FinishFlourish", default: 0] - before
            try? await Task.sleep(for: .seconds(1))
            let after = bodyCounts["FinishFlourish", default: 0] - before - during
            lines.append("frames drawn while it played: \(during > 10 ? "many" : "\(during)") · after it ended: \(after)")
            lines.append("done")
        }
    }

    /// `-BlitMonthlyTotalsTest <log> -BlitTransferLogPath <file> -BlitJobLogPath <file>`:
    /// the months (PRD R4.4) from a written transfer log and jobs log: two
    /// months' totals, verification and speeds, this month's line, and a
    /// record written later showing up. With `-BlitShowTransferLog YES
    /// -transferLogShowsMonths YES`, <log>.wid has the Transfer Log window.
    static func runMonthlyTotalsTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitMonthlyTotalsTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            guard TransferLog.url.path.hasPrefix(NSTemporaryDirectory()) || TransferLog.url.path.hasPrefix("/private/tmp") || TransferLog.url.path.hasPrefix("/tmp"),
                  JobLog.url.path != URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support/Blit/jobs.jsonl").path else {
                return lines.append("refused: -BlitTransferLogPath and -BlitJobLogPath must point at temporary files")
            }
            var calendar = Calendar.current
            calendar.timeZone = .current
            func day(_ month: Int, _ day: Int) -> Date { calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))! }
            func record(_ time: Date, _ name: String, _ size: UInt64, _ verification: String, failed: Bool = false) -> TransferRecord {
                TransferRecord(time: time, source: "seedbox:/" + name, destination: "/Volumes/SSD/" + name, size: size, sha256: nil,
                               verification: verification, result: failed ? "failed" : "ok", detail: failed ? "stalled" : nil)
            }
            let records = [
                record(day(9, 3), "a.mkv", 10_000_000_000, "server-sha256"),
                record(day(9, 3), "b.mkv", 10_000_000_000, "server-sha256"),
                record(day(9, 20), "c.mkv", 10_000_000_000, "read-back"),
                record(day(9, 21), "d.mkv", 5_000_000_000, "size-only"),
                record(day(9, 22), "e.mkv", 7_000_000_000, "already-present"),
                record(day(9, 22), "f.mkv", 1_000_000_000, "none", failed: true),
                record(day(10, 2), "g.mkv", 12_000_000_000, "nas-sha256"),
                record(day(10, 4), "h.mkv", 12_000_000_000, "nas-sha256"),
                record(day(10, 4), "i.mkv", 3_000_000_000, "cloned"),
            ]
            let jobs = [
                JobRecord(time: day(9, 3), kind: "download", bytes: 30_000_000_000, seconds: 400, files: 3),
                JobRecord(time: day(9, 21), kind: "copy", bytes: 20_000_000_000, seconds: 190, files: 2),
                JobRecord(time: day(10, 4), kind: "copy", bytes: 24_000_000_000, seconds: 230, files: 2),
            ]
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            func jsonl<T: Encodable>(_ items: [T]) -> Data {
                items.reduce(Data()) { data, item in data + ((try? encoder.encode(item)) ?? Data()) + Data([0x0A]) }
            }
            try? jsonl(records).write(to: TransferLog.url)
            try? jsonl(jobs).write(to: JobLog.url)
            defer {
                try? FileManager.default.removeItem(at: TransferLog.url)
                try? FileManager.default.removeItem(at: JobLog.url)
            }
            TransferStats.shared.load()
            for _ in 0..<30 where TransferStats.shared.months.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
            for month in TransferStats.shared.months { lines.append("\(month.title): \(month.summary)") }
            lines.append("this month: \(TransferStats.shared.thisMonth.map { "\($0.title): \($0.summary)" } ?? "none")")
            // A file finishes later this month: the months follow, a moment after.
            if let handle = try? FileHandle(forWritingTo: TransferLog.url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: jsonl([record(day(10, 5), "j.mkv", 6_000_000_000, "nas-sha256")]))
                try? handle.close()
            }
            TransferStats.shared.changed()
            try? await Task.sleep(for: .seconds(4))
            lines.append("after another file: \(TransferStats.shared.months.first.map { "\($0.title): \($0.summary)" } ?? "none")")
            lines.append("nothing logged: \(MonthTotals.make(records: [], jobs: []).count) months")
            if UserDefaults.standard.bool(forKey: "BlitShowTransferLog") {
                try? await Task.sleep(for: .seconds(1))
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.title == "Transfer Log" }) {
                    try? String(window.windowNumber).write(toFile: logPath + ".wid", atomically: true, encoding: .utf8)
                    for _ in 0..<100 where !FileManager.default.fileExists(atPath: logPath + ".shot") { try? await Task.sleep(for: .milliseconds(100)) }
                } else {
                    lines.append("no Transfer Log window")
                }
            }
            lines.append("done")
        }
    }

    /// `-BlitFolderSummaryTest <log> -BlitFolderSummaryTestVideo <header.mkv>`:
    /// Space on a release folder (PRD R2.17): a big episode made from a real
    /// HDR10 header, a smaller one, a sample, a hidden file and a DOS-encoded
    /// .nfo. The page's text, Space again closing it, and the page reused
    /// when it's fresh. Writes <log>.wid with Quick Look's window for a picture.
    static func runFolderSummaryTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitFolderSummaryTest"),
              let header = UserDefaults.standard.string(forKey: "BlitFolderSummaryTestVideo") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-folder-summary")
            try? fm.removeItem(at: root)
            let pack = root.appendingPathComponent("Show.S01.2160p.WEB-DL.DV-GRP")
            try? fm.createDirectory(at: pack.appendingPathComponent("Sample"), withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: root) }
            @MainActor func sparse(_ name: String, _ size: UInt64, from source: String? = nil) {
                let url = pack.appendingPathComponent(name)
                if let source { try? fm.copyItem(atPath: source, toPath: url.path) } else { fm.createFile(atPath: url.path, contents: nil) }
                let handle = try? FileHandle(forWritingTo: url)
                try? handle?.truncate(atOffset: size)
                try? handle?.close()
            }
            sparse("Show.S01E01.mkv", 3_000_000_000, from: header)
            sparse("Show.S01E02.mkv", 2_500_000_000)
            sparse("Sample/show.sample.mkv", 50_000_000)
            sparse(".DS_Store", 6_148)
            // ╔══╗ / ║ GRP ║ / ╚══╝ in code page 437, with DOS line ends.
            let nfo: [UInt8] = [0xC9, 0xCD, 0xCD, 0xCD, 0xCD, 0xCD, 0xBB, 13, 10, 0xBA] + Array(" GRP ".utf8) + [0xBA, 13, 10,
                                0xC8, 0xCD, 0xCD, 0xCD, 0xCD, 0xCD, 0xBC, 13, 10]
            fm.createFile(atPath: pack.appendingPathComponent("show.nfo").path, contents: Data(nfo))
            guard let model = PaneTabs.shared.current?.first else { return lines.append("no pane") }
            model.open(.local(root))
            for _ in 0..<20 where model.items.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            guard let folder = model.items.first(where: { $0.name == pack.lastPathComponent }) else { return lines.append("no folder") }
            lines.append("previewable: folder \(model.isPreviewable(folder))")
            model.selection = [folder.location]
            let started = Date()
            model.togglePreview()   // Space
            for _ in 0..<50 where model.previewURL == nil { try? await Task.sleep(for: .milliseconds(100)) }
            guard let page = model.previewURL else { return lines.append("no page after \(Int(Date().timeIntervalSince(started) * 1000)) ms") }
            lines.append("page: \(page.lastPathComponent) · in Quick Look's folder \(page.path.hasPrefix(BrowserModel.quickLookFolder.path))")
            let html = (try? String(contentsOf: page, encoding: .utf8)) ?? ""
            let text = html.components(separatedBy: "<body>").last?
                .replacingOccurrences(of: "<br>", with: " / ")
                .replacing(/<[^>]+>/, with: "")
                .replacingOccurrences(of: "&amp;", with: "&")
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
            for line in text { lines.append("  " + line) }
            lines.append("hidden file listed: \(html.contains(".DS_Store"))")
            // A picture of Quick Look: the shell captures the window once it sees <log>.wid.
            try? await Task.sleep(for: .seconds(1.5))
            if let panel = NSApp.windows.first(where: { $0.isVisible && String(describing: type(of: $0)).contains("QLPreviewPanel") }) {
                try? String(panel.windowNumber).write(toFile: logPath + ".wid", atomically: true, encoding: .utf8)
                for _ in 0..<100 where !fm.fileExists(atPath: logPath + ".shot") { try? await Task.sleep(for: .milliseconds(100)) }
                lines.append("Quick Look panel shown")
            } else {
                lines.append("Quick Look panel not found")
            }
            model.togglePreview()   // Space again
            lines.append("Space again: closed \(model.previewURL == nil)")
            model.togglePreview()
            lines.append("and again within 30 s: the same page \(model.previewURL == page)")
            model.togglePreview()
            lines.append("done")
        }
    }

    /// `-BlitDropSpaceTest <log> -BlitDropSpaceTestDest <folder>` (with
    /// `-showSecondPane YES`, the folder on a small volume such as a 300 MB
    /// disk image): what a drop target says about free space (PRD R2.10) as
    /// stand-in drags come over the right pane: a file, a folder (summed in
    /// the background) onto one of its folders, a file too big for the volume,
    /// and a file from that same volume, which needs no room; with a sidebar
    /// row's shorter wording each time. Sparse files: sizes without the bytes.
    static func runDropSpaceTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitDropSpaceTest"),
              let destPath = UserDefaults.standard.string(forKey: "BlitDropSpaceTestDest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let source = fm.temporaryDirectory.appendingPathComponent("blit-drop-space")
            let dest = URL(fileURLWithPath: destPath)
            let elsewhere = dest.deletingLastPathComponent().appendingPathComponent(dest.lastPathComponent + "-elsewhere")
            for folder in [source, dest, elsewhere] { try? fm.removeItem(at: folder) }
            for folder in [source.appendingPathComponent("Pack"), dest.appendingPathComponent("Inside"), elsewhere] {
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            @MainActor func sparse(_ url: URL, _ size: UInt64) {
                fm.createFile(atPath: url.path, contents: nil)
                let handle = try? FileHandle(forWritingTo: url)
                try? handle?.truncate(atOffset: size)
                try? handle?.close()
            }
            sparse(source.appendingPathComponent("small.bin"), 10_000_000)
            sparse(source.appendingPathComponent("big.bin"), 5_000_000_000)
            sparse(source.appendingPathComponent("Pack/a.bin"), 20_000_000)
            sparse(source.appendingPathComponent("Pack/b.bin"), 30_000_000)
            sparse(elsewhere.appendingPathComponent("same.bin"), 100_000_000)
            defer { for folder in [source, dest, elsewhere] { try? fm.removeItem(at: folder) } }
            guard let first = PaneTabs.shared.current?.first, let window = BrowserModel.activeWindow,
                  let second = BrowserModel.oppositePane?(first) else { return lines.append("no second pane (showSecondPane off?)") }
            @MainActor func show(_ model: BrowserModel, _ url: URL) async {
                model.open(.local(url))
                model.sort(by: .name)
                for _ in 0..<30 where model.current?.localURL?.lastPathComponent != url.lastPathComponent || model.items.isEmpty {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            await show(first, source)
            await show(second, dest)
            for _ in 0..<30 where FreeSpace.shared.free(at: dest) == nil { try? await Task.sleep(for: .milliseconds(200)) }
            try? await Task.sleep(for: .milliseconds(500))
            guard let leftList = FileListRegistry.coordinator(for: first), let rightList = FileListRegistry.coordinator(for: second) else {
                return lines.append("no lists")
            }
            var sequence = 2000
            /// Drags `names` from the left pane over `target` in the right one
            /// (nil: its empty space); what the list and a sidebar row say.
            @MainActor func hover(_ names: [String], over target: String?) async {
                sequence += 1
                let items = first.rows.filter { names.contains($0.name) }
                DragSize.shared.measure(items, in: first)   // as the drag starts
                for _ in 0..<50 where DragSize.shared.measuring { try? await Task.sleep(for: .milliseconds(100)) }
                let board = NSPasteboard(name: NSPasteboard.Name("blit-drop-space-\(sequence)"))
                board.clearContents()
                board.writeObjects(first.rows.indices.filter { names.contains(first.rows[$0].name) }
                    .compactMap { leftList.tableView(leftList.table, pasteboardWriterForRow: $0) })
                let drag = StandInDrag(pasteboard: board, sequence: sequence, window: window)
                let table = rightList.table
                if let target, let row = second.rows.firstIndex(where: { $0.name == target }) {
                    let rect = table.rect(ofRow: row)
                    drag.location = table.convert(NSPoint(x: rect.minX + 60, y: rect.midY), to: nil)
                } else {
                    let last = table.rect(ofRow: max(0, table.numberOfRows - 1))
                    drag.location = table.convert(NSPoint(x: last.minX + 60, y: last.maxY + 40), to: nil)
                }
                rightList.dragEntered(drag)
                _ = rightList.tableView(table, validateDrop: drag, proposedRow: -1, proposedDropOperation: .on)
                try? await Task.sleep(for: .milliseconds(400))
                let label = rightList.dropSpace
                let onto = if case .folder(let folder) = rightList.dropHover.value { folder.lastComponent } else { "the list" }
                let shown = label.isHidden ? "no label" : "“\(label.summary?.text ?? "")”\(label.summary?.fits == false ? " in orange" : "")"
                let sidebar = DropSpace.summary(into: second.current!, compact: true).map { "“\($0.text)”" } ?? "nothing"
                lines.append("\(names.joined(separator: " + ")) over \(onto): \(shown) · a sidebar row: \(sidebar)")
                // -BlitDropSpacePictures YES: the right list alone, as it looks.
                if UserDefaults.standard.bool(forKey: "BlitDropSpacePictures"),
                   let rep = rightList.scrollView.bitmapImageRepForCachingDisplay(in: rightList.scrollView.bounds) {
                    rightList.scrollView.cacheDisplay(in: rightList.scrollView.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: logPath + "-\(sequence).png"))
                }
                rightList.dragExited()
                try? await Task.sleep(for: .milliseconds(300))
            }
            await hover(["small.bin"], over: nil)
            await hover(["Pack"], over: "Inside")
            await hover(["big.bin"], over: nil)
            await hover(["small.bin", "Pack"], over: nil)
            lines.append("after the drag left: label hidden \(rightList.dropSpace.isHidden)")
            await show(first, elsewhere)
            await hover(["same.bin"], over: nil)
            lines.append("done")
        }
    }

    /// `-BlitVideoColumnTest <log> -BlitVideoColumnTestDir <fixtures>`: the
    /// Video column over BlitMedia's test files (copied in with a folder, a
    /// text file and an .mkv that isn't one): each row's text and tooltip as
    /// the reads land, the forms at three column widths, and a file that
    /// changes being read again.
    static func runVideoColumnTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitVideoColumnTest"),
              let fixtures = UserDefaults.standard.string(forKey: "BlitVideoColumnTestDir") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-video-column")
            try? fm.removeItem(at: root)
            try? fm.createDirectory(at: root.appendingPathComponent("Extras"), withIntermediateDirectories: true)
            for name in (try? fm.contentsOfDirectory(atPath: fixtures)) ?? [] {
                try? fm.copyItem(atPath: fixtures + "/" + name, toPath: root.appendingPathComponent(name).path)
            }
            fm.createFile(atPath: root.appendingPathComponent("notes.txt").path, contents: Data("x".utf8))
            fm.createFile(atPath: root.appendingPathComponent("broken.mkv").path, contents: Data("not a video".utf8))
            defer { try? fm.removeItem(at: root) }
            guard let model = PaneTabs.shared.current?.first else { return lines.append("no pane") }
            let wasShown = ColumnSettings.shared.isShown("video")
            ColumnSettings.shared.set("video", shown: true)
            defer { ColumnSettings.shared.set("video", shown: wasShown) }
            VideoDetails.shared.reset()
            model.open(.local(root))
            model.sort(by: .name)
            try? await Task.sleep(for: .seconds(1))
            guard let table = FileListRegistry.table(for: model) else { return lines.append("no list") }
            let videoColumn = table.column(withIdentifier: FileColumn.video.identifier)
            guard videoColumn >= 0 else { return lines.append("no Video column") }
            lines.append("columns: " + table.tableColumns.filter { !$0.isHidden }.map(\.title).joined(separator: " | "))
            @MainActor func shown(_ label: String) async {
                for _ in 0..<50 where VideoDetails.shared.busy { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(500))
                lines.append("\(label) (column \(Int(table.tableColumns[videoColumn].width)) pt):")
                for row in 0..<table.numberOfRows {
                    let name = (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NameCellView)?.item?.name ?? "?"
                    let cell = table.view(atColumn: videoColumn, row: row, makeIfNecessary: false)
                    let text = cell?.accessibilityLabel() ?? "-"
                    lines.append("  \(name): \(text.isEmpty ? "(blank)" : text)")
                }
            }
            await shown("read")
            for name in ["hdr10-vui-head.mkv", "sdr-1080p.mp4"] {
                guard let row = model.rows.firstIndex(where: { $0.name == name }),
                      let tip = table.view(atColumn: videoColumn, row: row, makeIfNecessary: false)?.toolTip else { continue }
                lines.append("  tooltip \(name): " + tip.replacingOccurrences(of: "\n", with: " / "))
            }
            for width in [320.0, 80.0, 150.0] {
                table.tableColumns[videoColumn].width = width
                await shown("at \(Int(width)) pt")
            }
            // A file changes (its size): it's read again.
            let target = root.appendingPathComponent("sdr-1080p.mp4")
            try? fm.removeItem(at: target)
            try? fm.copyItem(atPath: fixtures + "/hdr10-2160p.mp4", toPath: target.path)
            model.reload()
            try? await Task.sleep(for: .milliseconds(800))
            await shown("sdr-1080p.mp4 replaced by a 2160p HDR10 file")
            lines.append("done")
        }
    }

    /// `-BlitCompareTest <log>` (with `-showSecondPane YES`): View › Compare
    /// Panes between an "SSD" and a "NAS" folder. Each row's mark, from the
    /// model and as its cell shows it, the path bar's counts and the menu
    /// item's check; then the marks following a copy verified there, a file
    /// arriving there, a folder opened in place, the same folder in both
    /// panes, and the switch going off.
    static func runCompareTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitCompareTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-compare")
            try? fm.removeItem(at: root)
            let left = root.appendingPathComponent("SSD"), right = root.appendingPathComponent("NAS")
            for folder in [left.appendingPathComponent("Season 1"), right.appendingPathComponent("Season 1"), right.appendingPathComponent("Clash")] {
                try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            for (folder, name, size) in [(left, "a.mkv", 10), (left, "b.mkv", 20), (left, "c.mkv", 30), (left, "d.mkv", 40), (left, "Clash", 1),
                                         (left, "Season 1/e01.mkv", 5), (right, "a.mkv", 10), (right, "b.mkv", 25), (right, "e.mkv", 50),
                                         (right, "d.mkv.blitpart", 12)] {
                fm.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data(count: size))
            }
            defer { try? fm.removeItem(at: root) }
            guard let first = PaneTabs.shared.current?.first, let second = BrowserModel.oppositePane?(first) else {
                return lines.append("no second pane (showSecondPane off?)")
            }
            @MainActor func show(_ model: BrowserModel, _ url: URL) async {
                model.open(.local(url))
                for _ in 0..<20 where model.current?.localURL?.lastPathComponent != url.lastPathComponent || model.items.isEmpty {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            await show(first, left)
            await show(second, right)
            first.sort(by: .name)
            second.sort(by: .name)
            try? await Task.sleep(for: .milliseconds(800))
            /// Each row as its cell shows it, and whether the cells agree with the model.
            @MainActor func marks(_ model: BrowserModel) -> String {
                let table = FileListRegistry.table(for: model)
                var agree = true
                let rows = model.rows.enumerated().map { index, item in
                    let cell = table?.view(atColumn: 0, row: index, makeIfNecessary: false) as? NameCellView
                    let summary = cell?.testSummary ?? "?"
                    let mark = model.comparison(for: item).map { "{\($0.text)}" }
                    if mark.map({ !summary.contains($0) }) ?? summary.contains("{") { agree = false }
                    return summary
                }
                return rows.joined(separator: " · ") + (agree ? "" : "  ‼︎ the cells don't match the model")
            }
            @MainActor func both(_ label: String) async {
                try? await Task.sleep(for: .milliseconds(700))
                lines.append("\(label):")
                lines.append("  SSD: \(marks(first))  [\(first.comparisonSummary() ?? "-")]")
                lines.append("  NAS: \(marks(second))  [\(second.comparisonSummary() ?? "-")]")
            }
            @MainActor func compareItem() -> NSMenuItem? {
                NSApp.mainMenu?.items.compactMap(\.submenu).first(where: { $0.title == "View" })?.items.first(where: { $0.title == "Compare Panes" })
            }
            @MainActor func toggle() {
                NSApp.mainMenu?.update()
                guard let item = compareItem(), let menu = item.menu else { return lines.append("no Compare Panes item") }
                menu.performActionForItem(at: menu.index(of: item))
            }
            @MainActor func menuState() -> String {
                // As the View menu opening would.
                if let view = compareItem()?.menu { view.delegate?.menuNeedsUpdate?(view); view.update() }
                guard let item = compareItem() else { return "no item" }
                let previews = item.menu?.items.first(where: { $0.title == "Show Icon Previews" })
                lines.append("  (Show Icon Previews: \(previews?.state == .on ? "checked" : "unchecked"), delegate \(item.menu?.delegate.map { String(describing: type(of: $0)) } ?? "none"))")
                return "\(item.state == .on ? "checked" : "unchecked") · enabled \(item.isEnabled) · \(item.keyEquivalentModifierMask.contains(.control) ? "⌃" : "")\(item.keyEquivalentModifierMask.contains(.command) ? "⌘" : "")\(item.keyEquivalent.uppercased())"
            }
            await both("off")
            lines.append("menu: \(menuState())")
            toggle()
            await both("on")
            lines.append("menu: \(menuState())")
            for item in first.rows {
                if let comparison = first.comparison(for: item) { lines.append("  help SSD/\(item.name): \(comparison.help)") }
            }
            if let cell = FileListRegistry.table(for: first).flatMap({ table in
                first.rows.firstIndex(where: { $0.name == "b.mkv" }).flatMap { table.view(atColumn: 0, row: $0, makeIfNecessary: false) }
            }) {
                lines.append("  b.mkv's VoiceOver label: \(cell.accessibilityLabel() ?? "-")")
            }
            // The NAS copy of a.mkv is verified (a transfer's record): no reload.
            VerifiedIndex.shared.record(TransferRecord(time: Date(timeIntervalSince1970: 1_790_000_000), source: "/elsewhere/a.mkv",
                                                       destination: right.appendingPathComponent("a.mkv").path, size: 10, sha256: nil,
                                                       verification: "read-back", result: "ok", detail: nil, cached: nil))
            await both("NAS a.mkv verified")
            if let a = first.rows.first(where: { $0.name == "a.mkv" }) { lines.append("  help SSD/a.mkv: \(first.comparison(for: a)?.help ?? "-")") }
            // A picture of every mark: the shell captures the window once it sees <log>.wid.
            if let window = FileListRegistry.table(for: first)?.window {
                try? String(window.windowNumber).write(toFile: logPath + ".wid", atomically: true, encoding: .utf8)
                for _ in 0..<100 where !fm.fileExists(atPath: logPath + ".shot") { try? await Task.sleep(for: .milliseconds(100)) }
            }
            // c.mkv arrives on the NAS; only the NAS pane reloads.
            fm.createFile(atPath: right.appendingPathComponent("c.mkv").path, contents: Data(count: 30))
            second.reload()
            for _ in 0..<20 where second.item(named: "c.mkv") == nil { try? await Task.sleep(for: .milliseconds(200)) }
            await both("c.mkv copied to the NAS")
            // A folder opened in place: what's inside isn't compared.
            if let season = first.rows.first(where: { $0.name == "Season 1" }) { first.toggleExpanded(season) }
            await both("Season 1 open on the SSD")
            if let season = first.rows.first(where: { $0.name == "Season 1" }) { first.toggleExpanded(season) }
            await show(second, left)
            await both("the same folder in both panes")
            await show(second, right)
            second.sort(by: .name)
            await both("back to the NAS")
            toggle()
            await both("switched off")
            lines.append("menu: \(menuState())")
            lines.append("done")
        }
    }

    /// `-BlitNativeCellsTest <log>`: the AppKit
    /// list's rows as its cells show them, through a stand-in transfer's
    /// statuses (after the name, then in the Status column), a verified file,
    /// a folder opened and closed with → and ←, a header-click sort and the
    /// header's menu.
    static func runNativeCellsTestIfRequested(transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitNativeCellsTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-native-cells")
            try? fm.removeItem(at: root)
            let dest = root.appendingPathComponent("Dest"), source = root.appendingPathComponent("Src")
            for folder in [dest.appendingPathComponent("Sub"), source] { try? fm.createDirectory(at: folder, withIntermediateDirectories: true) }
            for name in ["a.mkv", "b.mkv", "Sub/c.mkv"] { fm.createFile(atPath: dest.appendingPathComponent(name).path, contents: Data("x".utf8)) }
            guard let model = PaneTabs.shared.current?.first else { return lines.append("no pane") }
            model.open(.local(dest))
            model.sort(by: .name)
            try? await Task.sleep(for: .seconds(1.5))
            guard let table = FileListRegistry.table(for: model) else { return lines.append("no list") }
            @MainActor func shown(_ label: String) async {
                try? await Task.sleep(for: .milliseconds(600))
                var rows: [String] = []
                for row in 0..<table.numberOfRows {
                    let name = (table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NameCellView)?.testSummary ?? "?"
                    let statusColumn = table.column(withIdentifier: FileColumn.status.identifier)
                    let status = statusColumn >= 0 && !table.tableColumns[statusColumn].isHidden
                        ? (table.view(atColumn: statusColumn, row: row, makeIfNecessary: false)?.accessibilityLabel() ?? "") : ""
                    rows.append(status.isEmpty ? name : "\(name) | \(status)")
                }
                lines.append("\(label): " + rows.joined(separator: " · "))
            }
            await shown("listed")
            // A stand-in copy into Dest: a.mkv on its way, b.mkv cloned.
            let job = TransferJob(kind: .copy, sources: [.local(source.appendingPathComponent("a.mkv")), .local(source.appendingPathComponent("b.mkv"))],
                                  destination: dest, title: "a.mkv", destinationName: "Dest")
            job.persistent = false
            job.status = .running
            job.inFlight = ["a.mkv"]
            job.outcomes = ["b.mkv": "cloned"]
            transfers.debugInsert(job)
            await shown("copying")
            // A picture of the marks: the shell captures the window once it sees <log>.wid.
            if let window = table.window {
                try? String(window.windowNumber).write(toFile: logPath + ".wid", atomically: true, encoding: .utf8)
                for _ in 0..<100 where !fm.fileExists(atPath: logPath + ".shot") { try? await Task.sleep(for: .milliseconds(100)) }
            }
            job.inFlight = []
            job.outcomes["a.mkv"] = "read-back"
            await shown("a.mkv verified")
            let hidden = ColumnSettings.shared.isShown("status")
            ColumnSettings.shared.set("status", shown: true)
            await shown("Status column shown")
            ColumnSettings.shared.set("status", shown: hidden)
            job.status = .finished
            transfers.debugRemove(job)
            await shown("transfer gone")
            // → and ← on the folder, as typed.
            guard let sub = model.rows.first(where: { $0.name == "Sub" }) else { return lines.append("no Sub") }
            model.selection = [sub.location]
            try? await Task.sleep(for: .milliseconds(300))
            @MainActor func press(_ code: UInt16) {
                guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                   windowNumber: table.window?.windowNumber ?? 0, context: nil,
                                                   characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else { return }
                table.keyDown(with: event)
            }
            press(124)
            await shown("→ on Sub")
            if let inside = model.rows.first(where: { $0.depth == 1 }) { model.selection = [inside.location] }
            try? await Task.sleep(for: .milliseconds(300))
            press(123)
            await shown("← inside Sub")
            lines.append("selected: \(model.selectedItems.map(\.name))")
            // A click on Sub's disclosure triangle (posted to this copy: the
            // pointer never moves) opens it; another closes it. The row's
            // selection stays as it was.
            @MainActor func clickTriangle() async -> String {
                guard let row = model.rows.firstIndex(where: { $0.name == "Sub" }),
                      let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? NameCellView else { return "no Sub cell" }
                let inCell = NSPoint(x: cell.disclosureFrame.midX, y: cell.disclosureFrame.midY)
                let at = cell.convert(inCell, to: nil)
                let hit = table.window?.contentView.map { content in content.hitTest(content.convert(at, from: nil)).map { "\(type(of: $0))" } ?? "nothing" } ?? "-"
                for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                    if let event = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                      windowNumber: table.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
                                                      clickCount: 1, pressure: 1) {
                        NSApp.postEvent(event, atStart: false)
                    }
                    try? await Task.sleep(for: .milliseconds(80))
                }
                try? await Task.sleep(for: .milliseconds(500))
                return "hit \(hit)"
            }
            model.selection = []
            let firstClick = await clickTriangle()
            await shown("click on Sub's triangle (\(firstClick))")
            let secondClick = await clickTriangle()
            await shown("click on it again (\(secondClick))")
            lines.append("selected after the clicks: \(model.selectedItems.map(\.name))")
            // A header click: Size, largest first (as Finder starts it).
            table.sortDescriptors = [FileColumn.size.sortPrototype].compactMap { $0 }
            await shown("sorted by size")
            lines.append("model sort: \(model.sortColumn?.rawValue ?? "-") \(model.sortOrder.first?.order == .reverse ? "descending" : "ascending")")
            if let menu = table.headerView?.menu {
                menu.delegate?.menuNeedsUpdate?(menu)
                lines.append("header menu: " + menu.items.map {
                    $0.isSeparatorItem ? "—" : "\($0.title)\($0.state == .on ? " ✓" : "")\($0.isEnabled ? "" : " (disabled)")"
                }.joined(separator: " | "))
            }
            try? fm.removeItem(at: root)
            lines.append("done")
        }
    }

    /// The process's memory footprint, as Activity Monitor's Memory column.
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
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

            // New Folder with Selection: offered for two or more items in one
            // folder; the folder and the move are one step to undo.
            let second = root.appendingPathComponent("c.txt")
            try? Data("c".utf8).write(to: second)
            if let browser = BrowserModel.active {
                @MainActor func item(_ url: URL, isDirectory: Bool = false) -> FileItem {
                    FileItem(location: .local(url), name: url.lastPathComponent, isDirectory: isDirectory, modified: Date(), size: 1, kind: "Text")
                }
                @MainActor func offered(_ items: [FileItem]) -> [String] {
                    FileMenuBuilder.items(for: items, in: browser).map(\.title).filter { $0.hasPrefix("New Folder with") }
                }
                let inside = root.appendingPathComponent("sub/d.txt")
                lines.append("menu: one item \(offered([item(file)])) · two \(offered([item(file), item(second)])) · two in different folders \(offered([item(file), item(inside)]))")
            }
            let made = try? await operations.makeFolder(named: "New Folder With Items", in: .local(root), moving: [.local(file), .local(second)])
            lines.append("after new folder with selection: \(listing()) · made \(made?.folder.lastComponent ?? "none") · problem \(made?.problem ?? "none") · undo: \(undo.undoActionName)")
            undo.undo(); await settle()
            lines.append("after undo:   \(listing())")

            // Rename With Preset: each preset titled with what it would do;
            // applied as one rename, one step to undo.
            let movie = root.appendingPathComponent("The.Gentlemen.2019.UHD.BluRay.2160p.mkv")
            let show = root.appendingPathComponent("South.Park.S29E01.1080p.WEB.h264-GRACE.mkv")
            for url in [movie, show] { fm.createFile(atPath: url.path, contents: Data("x".utf8)) }
            if let browser = BrowserModel.active {
                @MainActor func fileItem(_ url: URL) -> FileItem {
                    FileItem(location: .local(url), name: url.lastPathComponent, isDirectory: false, modified: Date(), size: 1, kind: "Video")
                }
                @MainActor func presets(_ items: [FileItem]) -> NSMenu? {
                    FileMenuBuilder.items(for: items, in: browser).first { $0.title == "Rename With Preset" }?.submenu
                }
                @MainActor func describe(_ menu: NSMenu?) -> String {
                    (menu?.items ?? []).map { $0.isSeparatorItem ? "—" : $0.title + ($0.isEnabled ? "" : " (off)") }.joined(separator: " | ")
                }
                lines.append("presets for the movie: \(describe(presets([fileItem(movie)])))")
                let both = presets([fileItem(movie), fileItem(show)])
                lines.append("presets for both: \(describe(both))")
                if let both, let index = both.items.firstIndex(where: { $0.title.hasPrefix("Movies") }) {
                    both.performActionForItem(at: index)
                }
                await settle(); await settle()
                lines.append("after the Movies preset: \(listing()) · undo: \(undo.undoActionName)")
                undo.undo(); await settle()
                lines.append("after undo:   \(listing())")
            }
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
                lines.append("drag \(index + 1) (\(step.label)): stall \(String(format: "%.1f", longest)) s · favorites \(favorites) · \(places.joined(separator: " · ")) · still lit \(DragHoverRegistry.anyShowing) · \(UITestHarness.dropTrail.filter { $0.hasPrefix("late") || $0.hasPrefix("highlight") })")
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
            let tables = fileLists(in: window)
            guard let leftTable = tables.first else {
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
                fileLists(in: window).map { $0.tableColumns.filter { !$0.isHidden }.count }
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
            let tables = fileLists(in: window)
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
            @MainActor func clip(_ model: BrowserModel) -> NSClipView? { FileListRegistry.scrollView(for: model)?.contentView }
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
                try? tabs.tabs.map(\.id.uuidString).joined(separator: "\n")
                    .write(to: root.appendingPathComponent("ids"), atomically: true, encoding: .utf8)
                lines.append("saved \(tabs.tabs.count) tabs")
            } else {
                // The shown tab opens its folders; the others wait until shown.
                try? await Task.sleep(for: .seconds(1))
                lines.append("restored \(tabs.tabs.count) tabs · shown \((tabs.selectedIndex ?? -1) + 1) · right pane active \(tabs.current?.secondActive ?? false)")
                // Their ids too: a restored transfer finds the tab it was started from.
                let ids = (try? String(contentsOf: root.appendingPathComponent("ids"), encoding: .utf8)) ?? ""
                lines.append("same ids \(ids == tabs.tabs.map(\.id.uuidString).joined(separator: "\n"))")
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

    /// How many times each instrumented view's body has run (the busy test
    /// reads how often the window redraws during a transfer).
    static var bodyCounts: [String: Int] = [:]
    @discardableResult static func tick(_ name: String) -> Int {
        bodyCounts[name, default: 0] += 1
        return 0
    }

    /// The tab shown as the last click's button came up (the real-input tabs test).
    static var shownAtRelease: Int?

    /// Where each queue row's buttons sit in the HUD (the queue click test).
    static var queueControls: [UUID: CGRect] = [:]


    /// `-BlitTabsKeysTest <log>`: the tabs with real keys and clicks, sent by
    /// scripts/ui-keys (steps 0–9) and ui-drag (one drag), both of which act
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
                guard tabs.tabs.indices.contains(index), let frame = TabPress.spots[tabs.tabs[index].id]?.tab,
                      let content = window.contentView else { return [] }
                // Right of the ⌘-number (hovering there shows the close button).
                return cg(NSPoint(x: frame.midX + 20, y: content.bounds.height - frame.midY))
            }
            // Bring this copy forward with a click on the left list's empty space.
            let tables = fileLists(in: window)
            guard let table = tables.first else {
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
            // The tab shown as each click's button comes up: a local monitor sees the
            // release before the tab bar does, so a tab chosen on the press already shows.
            let releases = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
                MainActor.assumeIsolated { shownAtRelease = (PaneTabs.shared.selectedIndex ?? -1) + 1 }
                return event
            }
            defer { releases.map(NSEvent.removeMonitor) }
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
            lines.append("click on tab 2: shows \(shown()) · already shown as the button came up \(shownAtRelease == 2)")
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
            await step(7, 17, 1)                                      // ⌘T
            lines.append("⌘T: \(tabs.tabs.count) tabs · shows \(shown())")
            // A click on a tab's close button (the ⌘-number, hovered) closes it, never showing it first.
            let showing = tabs.current?.id
            let closing = tabs.tabs.first { $0.id != showing }
            let button = closing.flatMap { TabPress.spots[$0.id]?.close }.map { frame -> [Int] in
                guard let content = window.contentView else { return [] }
                return cg(NSPoint(x: frame.midX, y: content.bounds.height - frame.midY))
            } ?? []
            shownAtRelease = nil
            await step(8, -1, 0, click: button)                       // click a tab's close button
            lines.append("close button on another tab: \(tabs.tabs.count) tabs · it's gone \(!tabs.tabs.contains { $0.id == closing?.id })"
                         + " · the shown tab stayed \(tabs.current?.id == showing) · shown as the button came up \(shownAtRelease.map(String.init) ?? "-")")
            await step(9, 13, 1)                                      // ⌘W
            lines.append("⌘W: \(tabs.tabs.count) tab · window open \(window.isVisible)")
            lines.append("done")
        }
    }

    /// `-BlitTabsDragTest <log>`: the tab bar with five tabs: tabs that fill it
    /// (never wider, which used to push the window's panes off its edges, a
    /// picture at <log>.shot once the shell has captured <log>.wid), the sums
    /// it does, and with `-BlitTabsDragReal YES` real drags along it, sent by
    /// scripts/ui-drag (it acts only while this copy is in front): steady ones
    /// to the far left, the far right, one slot and out over the sidebar
    /// (<log>-slow), then quick flicks to each end (<log>-fast). Logs the
    /// order after each.
    static func runTabsDragTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitTabsDragTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let root = fm.temporaryDirectory.appendingPathComponent("blit-tabs-drag")
            try? fm.removeItem(at: root)
            for name in ["Left", "Right"] { try? fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true) }
            let tabs = PaneTabs.shared
            guard let window = BrowserModel.activeWindow, let tab = tabs.current, let second = tab.second,
                  let content = window.contentView else { return lines.append("no window or second pane") }
            let real = UserDefaults.standard.bool(forKey: "BlitTabsDragReal")
            window.setFrame(NSRect(x: 100, y: 100, width: 1280, height: 760), display: true)
            if real {
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
            } else {
                window.makeKey()
            }
            tab.first.open(.local(root.appendingPathComponent("Left")))
            second.open(.local(root.appendingPathComponent("Right")))
            for _ in 0..<4 { tabs.newTab() }
            for (tab, name) in zip(tabs.tabs, ["A", "B", "C", "D", "E"]) { tabs.rename(tab.id, to: name) }
            try? await Task.sleep(for: .seconds(1.5))
            @MainActor func order() -> String { tabs.tabs.map { $0.customName ?? "?" }.joined(separator: " ") }
            @MainActor func tabRect(_ index: Int) -> CGRect? {
                tabs.tabs.indices.contains(index) ? TabPress.spots[tabs.tabs[index].id]?.tab : nil
            }
            guard let first = tabRect(0), let last = tabRect(4) else { return lines.append("no tab frames") }
            // The sums the bar does: tab widths that fill it, and the slot a drag lands in.
            let step = PaneTabBar.tabWidth(barWidth: 1100, count: 5) + 4
            lines.append("math: width 1100 → \(Int(step - 4)) per tab (5), \(Int(PaneTabBar.tabWidth(barWidth: 1100, count: 2))) (2), \(Int(PaneTabBar.tabWidth(barWidth: 1100, count: 14))) (14)"
                         + " · slot for left edge -500 → \(PaneTabBar.slot(pointer: -480, grab: 20, step: step, count: 5) + 1), 0 → \(PaneTabBar.slot(pointer: 20, grab: 20, step: step, count: 5) + 1)"
                         + ", 1.4 slots → \(PaneTabBar.slot(pointer: 20 + 1.4 * step, grab: 20, step: step, count: 5) + 1), 1.6 → \(PaneTabBar.slot(pointer: 20 + 1.6 * step, grab: 20, step: step, count: 5) + 1)"
                         + ", far right → \(PaneTabBar.slot(pointer: 5000, grab: 20, step: step, count: 5) + 1)")
            lines.append("start: \(order()) · tabs \(Int(first.width)) wide, first at x \(Int(first.minX)), last ends at x \(Int(last.maxX))"
                         + " · window \(Int(window.frame.width)) wide · fits \(last.maxX + 4 + 24 + 8 <= content.bounds.width + 0.5)")
            // A picture of the bar: the shell captures the window once it sees <log>.wid.
            try? String(window.windowNumber).write(toFile: logPath + ".wid", atomically: true, encoding: .utf8)
            for _ in 0..<100 where !fm.fileExists(atPath: logPath + ".shot") { try? await Task.sleep(for: .milliseconds(100)) }
            guard real else {
                try? fm.removeItem(at: root)
                return lines.append("(drags need -BlitTabsDragReal YES: real input)\ndone")
            }
            let screenHeight = NSScreen.screens.first?.frame.height ?? 0
            @MainActor func cg(_ x: CGFloat, _ y: CGFloat) -> [Int] {
                let screen = window.convertPoint(toScreen: NSPoint(x: x, y: content.bounds.height - y))
                return [Int(screen.x), Int(screenHeight - screen.y)]
            }
            var counts = ["slow": 0, "fast": 0]
            /// Drags the tab named `name` (from right of its ⌘-number) to x `toX`
            /// in the window, by ui-drag's `run` (slow or fast).
            @MainActor func drag(_ label: String, _ name: String, toX: CGFloat, run: String) async {
                guard let index = tabs.tabs.firstIndex(where: { $0.customName == name }), let frame = tabRect(index) else {
                    return lines.append("\(label): no tab \(name)")
                }
                let n = counts[run] ?? 0
                counts[run] = n + 1
                let prefix = logPath + "-" + run
                let from = cg(frame.midX + 20, frame.midY), to = cg(toX, frame.midY)
                try? JSONSerialization.data(withJSONObject: from + to).write(to: URL(fileURLWithPath: prefix + ".points-\(n)"))
                for _ in 0..<200 where !fm.fileExists(atPath: prefix + ".hover-\(n)") && !fm.fileExists(atPath: prefix + ".aborted") {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                try? await Task.sleep(for: .seconds(2.5))   // ui-drag lets go about a second after hovering
                lines.append("\(label): \(order()) · shows \(tabs.current?.customName ?? "?")"
                             + (fm.fileExists(atPath: prefix + ".aborted") ? " · ui-drag stopped" : ""))
            }
            @MainActor func edge(_ index: Int) -> CGRect { tabRect(index) ?? first }
            await drag("D to the far left (expect D A B C E)", "D", toX: edge(0).minX - 20, run: "slow")
            await drag("C to the far right (expect D A B E C)", "C", toX: edge(4).maxX + 20, run: "slow")
            await drag("B one slot left (expect D B A E C)", "B", toX: edge(1).midX - 10, run: "slow")
            await drag("E out over the sidebar (expect E D B A C)", "E", toX: edge(0).minX - 120, run: "slow")
            await drag("C flicked to the far left (expect C E D B A)", "C", toX: edge(0).minX - 20, run: "fast")
            await drag("D flicked to the far right (expect C E B A D)", "D", toX: edge(4).maxX + 20, run: "fast")
            try? fm.removeItem(at: root)
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
            @MainActor func tables() -> [NSTableView] { fileLists(in: window) }
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
                    let anchored = FileListRegistry.browser(at: point, in: window) != nil
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
            let tables = fileLists(in: window)
            guard let table = tables.first,
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
            let list = FileListRegistry.coordinator(for: browser)
            @MainActor func pressedOffName() -> Bool { list?.pressedOffName ?? false }
            for (label, x) in [("on the name", nameRect.minX + 40), ("blank part of the Name column", nameRect.maxX - 20)] {
                let local = NSPoint(x: x, y: table.rect(ofRow: 0).midY)
                lines.append("press \(label): moves files \(list?.dragsFiles(from: local) ?? false)")
            }
            // Press on the date of the first row, move down over three more, release.
            let start = point(row: 0, column: dateColumn)
            post(.leftMouseDown, start)
            for row in 1...3 { post(.leftMouseDragged, point(row: row, column: dateColumn)) }
            post(.leftMouseUp, point(row: 3, column: dateColumn))
            try? await Task.sleep(for: .seconds(1.5))
            lines.append("press on the date: pressed off the name \(pressedOffName()) · selected \(browser.selectedItems.map(\.name))")
            let widths = table.tableColumns.filter { !$0.isHidden }.map { "\($0.title) \(Int($0.width))" }
            lines.append("columns: \(widths.joined(separator: ", ")) · table width \(Int(table.bounds.width)) · clip \(Int(table.enclosingScrollView?.contentView.bounds.width ?? 0))")
            // A press on a name sets the table up for a file drag again.
            post(.leftMouseDown, point(row: 4, column: nameColumn, x: nameRect.minX + 40))
            post(.leftMouseUp, point(row: 4, column: nameColumn, x: nameRect.minX + 40))
            try? await Task.sleep(for: .seconds(1))
            lines.append("press on a name: pressed off the name \(pressedOffName())")
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
            let tables = fileLists(in: window)
            guard let table = tables.first,
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
            // -BlitRemoteDragReversed: the server on the right and the local folder on
            // the left, dragged right to left (the user's layout).
            let reversed = UserDefaults.standard.bool(forKey: "BlitRemoteDragReversed")
            let serverPane = reversed ? second : tab.first, localPane = reversed ? tab.first : second
            // -BlitRemoteDragLocalSource: a local folder in the server's place (is it the server, or the other pane?).
            if UserDefaults.standard.bool(forKey: "BlitRemoteDragLocalSource") {
                let source = fm.temporaryDirectory.appendingPathComponent("blit-remote-drag-source")
                try? fm.removeItem(at: source)
                try? fm.createDirectory(at: source.appendingPathComponent("Folder"), withIntermediateDirectories: true)
                for name in ["a.nfo", "b.mkv", "c.mkv"] { fm.createFile(atPath: source.appendingPathComponent(name).path, contents: Data("x".utf8)) }
                fm.createFile(atPath: source.appendingPathComponent("Folder/inner.nfo").path, contents: Data("x".utf8))
                serverPane.open(.local(source))
            } else {
                serverPane.open(server.startLocation)
            }
            localPane.open(.local(local))
            for _ in 0..<100 where serverPane.rows.isEmpty { try? await Task.sleep(for: .milliseconds(200)) }
            // -BlitRemoteDragChild: a file inside an expanded server folder instead
            // (the user's freeze: the file came from a folder opened in place).
            if UserDefaults.standard.bool(forKey: "BlitRemoteDragChild") {
                for folder in serverPane.rows.filter(\.isDirectory).prefix(8) {
                    serverPane.toggleExpanded(folder)
                    for _ in 0..<50 where serverPane.loadingChildren.contains(folder.location) || !serverPane.expanded.contains(folder.location) {
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                    if serverPane.rows.contains(where: { $0.depth == 1 && !$0.isDirectory }) { break }
                    serverPane.toggleExpanded(folder)
                }
            }
            let childOnly = UserDefaults.standard.bool(forKey: "BlitRemoteDragChild")
            // The smallest file at the top of the server folder, with a namesake here.
            guard let file = serverPane.rows.filter({ !$0.isDirectory && (!childOnly || $0.depth == 1) })
                    .min(by: { ($0.size ?? .max) < ($1.size ?? .max) }) else {
                return lines.append("no file on the server (\(serverPane.rows.count) rows, error \(serverPane.error ?? "none"))")
            }
            let name = ConflictPrompt.name(for: file.location)
            // -BlitRemoteDragTwice: the first drag downloads the file for real, the
            // second drags it again onto its verified copy (the user's freeze).
            let twice = UserDefaults.standard.bool(forKey: "BlitRemoteDragTwice")
            if !twice { fm.createFile(atPath: local.appendingPathComponent(name).path, contents: Data("x".utf8)) }
            localPane.reload()
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
            let tables = fileLists(in: window)
            guard tables.count == 2, let row = serverPane.rows.firstIndex(where: { $0.id == file.id }) else { return lines.append("tables \(tables.count)") }
            let height = NSScreen.screens.first?.frame.height ?? 0
            @MainActor func cg(_ table: NSTableView, _ p: NSPoint) -> [Double] {
                let s = window.convertPoint(toScreen: table.convert(p, to: nil)); return [s.x, height - s.y]
            }
            let serverTable = tables[reversed ? 1 : 0], localTable = tables[reversed ? 0 : 1]
            let rect = serverTable.rect(ofRow: row)
            let from = cg(serverTable, NSPoint(x: rect.minX + 90, y: rect.midY))
            let seen = localTable.visibleRect
            var to = cg(localTable, NSPoint(x: seen.midX, y: seen.minY + seen.height * 0.6))
            // -BlitDragOutEnd "x,y": onto another app instead (a Finder window the test opened).
            if let custom = UserDefaults.standard.string(forKey: "BlitDragOutEnd")?.split(separator: ",").compactMap({ Double($0) }),
               custom.count == 2 { to = custom }
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
                localPane.reload()
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
                if second % 5 == 0 {
                    lines.append("heartbeat +\(second) s · longest stall \(String(format: "%.1f", longest)) s · a drop highlight showing \(DragHoverRegistry.anyShowing) · \(UITestHarness.dropTrail.filter { $0.hasPrefix("late") || $0.hasPrefix("highlight") })")
                }
            }
            ConflictPrompt.testAnswer = nil
            lines.append("done")
        }
    }

    /// `-BlitCloudTest <log>`: iCloud Drive and File Provider folders (Proton
    /// Drive…) with real files, in a folder "Blit test" in each (removed after):
    /// the pane's title, a verified copy in, the copy made online-only ("Remove
    /// Download"), then copied back out (a clone would copy the placeholder, so
    /// Blit reads it, which downloads it) and moved out, each checked by SHA-256.
    static func runCloudTestIfRequested(operations: FileOperations, transfers: TransferManager) {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitCloudTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let local = fm.temporaryDirectory.appendingPathComponent("blit-cloud-test")
            try? fm.removeItem(at: local)
            try? fm.createDirectory(at: local.appendingPathComponent("back"), withIntermediateDirectories: true)
            // Two files of random data (a clone of a placeholder would read as zeros or fail).
            var names: [String] = []
            for name in ["copy-me.bin", "move-me.bin"] {
                var bytes = [UInt8](repeating: 0, count: 3 << 20)
                for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
                fm.createFile(atPath: local.appendingPathComponent(name).path, contents: Data(bytes))
                names.append(name)
            }
            func sha(_ url: URL) async -> String {
                await Task.detached {
                    guard let data = try? Data(contentsOf: url) else { return "unreadable" }
                    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(12).description
                }.value
            }
            @MainActor func waitForJobs() async -> String {
                for _ in 0..<600 {
                    try? await Task.sleep(for: .milliseconds(200))
                    let busy = transfers.jobs.contains { $0.isActive || $0.status == .queued || $0.status == .preparing }
                    if !busy { break }
                }
                return transfers.jobs.last.map { "\($0.status) · \($0.filesVerified)/\($0.fileCount) verified" } ?? "no job"
            }
            let originals = [await sha(local.appendingPathComponent(names[0])), await sha(local.appendingPathComponent(names[1]))]
            lines.append("cloud folders: \(CloudFolders.roots.map(\.name))")
            for cloud in CloudFolders.roots {
                let test = cloud.url.appendingPathComponent("Blit test")
                lines.append("== \(cloud.name)")
                // The first access may ask the user for permission: wait for it.
                var created = false
                for _ in 0..<120 {
                    if (try? fm.createDirectory(at: test, withIntermediateDirectories: true)) != nil { created = true; break }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                guard created else { lines.append("couldn't create \(test.lastPathComponent) (permission?)"); continue }
                if let browser = PaneTabs.shared.current?.first {
                    browser.open(.local(cloud.url))
                    try? await Task.sleep(for: .seconds(1.5))
                    lines.append("pane title \(browser.title) · rows \(browser.rows.count)")
                }
                // 1. A copy in (same disk: a clone).
                let result1 = await operations.place(names.map { .local(local.appendingPathComponent($0)) }, into: .local(test),
                                                     destinationName: "Blit test", mode: .copy)
                let state1 = await waitForJobs()
                let in0 = await sha(test.appendingPathComponent(names[0])), in1 = await sha(test.appendingPathComponent(names[1]))
                lines.append("copy in: \(state1) · \(result1 ?? "no message") · hashes match \(in0 == originals[0] && in1 == originals[1])")
                // 2. Online-only: "Remove Download" (the provider has to have uploaded them first).
                var evicted: [Bool] = []
                for name in names {
                    let url = test.appendingPathComponent(name)
                    var done = false
                    for _ in 0..<60 {
                        do { try fm.evictUbiquitousItem(at: url) } catch {}
                        try? await Task.sleep(for: .milliseconds(500))
                        if CloudFolders.isDataless(url.path) { done = true; break }
                    }
                    evicted.append(done)
                }
                lines.append("made online-only: \(evicted)")
                // 3. Copy the first back out, and move the second out.
                let result3 = await operations.place([.local(test.appendingPathComponent(names[0]))], into: .local(local.appendingPathComponent("back")),
                                                     destinationName: "back", mode: .copy)
                let state3 = await waitForJobs()
                let out0 = await sha(local.appendingPathComponent("back/\(names[0])"))
                lines.append("copy out: \(state3) · \(result3 ?? "no message") · data intact \(out0 == originals[0])")
                try? fm.removeItem(at: local.appendingPathComponent("back/\(names[1])"))
                let result4 = await operations.place([.local(test.appendingPathComponent(names[1]))], into: .local(local.appendingPathComponent("back")),
                                                     destinationName: "back", mode: .move)
                let state4 = await waitForJobs()
                let out1 = await sha(local.appendingPathComponent("back/\(names[1])"))
                lines.append("move out: \(state4) · \(result4 ?? "no message") · data intact \(out1 == originals[1]) · gone from \(cloud.name) \(!fm.fileExists(atPath: test.appendingPathComponent(names[1]).path))")
                // Tidy up: the test folder and the copies brought back.
                do { try fm.removeItem(at: test); lines.append("removed Blit test from \(cloud.name)") }
                catch { lines.append("couldn't remove Blit test: \(error.localizedDescription)") }
                for name in names { try? fm.removeItem(at: local.appendingPathComponent("back/\(name)")) }
            }
            try? fm.removeItem(at: local)
            lines.append("done")
        }
    }

    /// The Open With submenu the menu test saw.
    static var openWithSubmenu: NSMenu?

    /// `-BlitOpenWithMenuTest <log>`: right-click (posted to this copy's own
    /// queue: the pointer never moves) a video file and read the Open With
    /// submenu: each app's title and whether it shows an icon.
    static func runOpenWithMenuTestIfRequested() {
        guard let logPath = UserDefaults.standard.string(forKey: "BlitOpenWithMenuTest") else { return }
        var lines: [String] = [] {
            didSet { try? lines.joined(separator: "\n").appending("\n").write(toFile: logPath, atomically: true, encoding: .utf8) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            let fm = FileManager.default
            let folder = fm.temporaryDirectory.appendingPathComponent("blit-open-with-menu")
            try? fm.removeItem(at: folder)
            try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
            fm.createFile(atPath: folder.appendingPathComponent("clip.mp4").path, contents: Data(count: 1024))
            guard let window = BrowserModel.activeWindow, let browser = PaneTabs.shared.current?.first else { return lines.append("no window") }
            browser.open(.local(folder))
            try? await Task.sleep(for: .seconds(1.5))
            let tables = fileLists(in: window)
            guard let table = tables.first,
                  let row = browser.rows.firstIndex(where: { $0.name == "clip.mp4" }) else { return lines.append("no row") }
            var described: [String] = []
            let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { note in
                nonisolated(unsafe) let menu = note.object as? NSMenu
                MainActor.assumeIsolated {
                    guard let items = menu?.items, described.isEmpty else { return }
                    let openWith = items.first { $0.title == "Open With" }
                    UITestHarness.openWithSubmenu = openWith?.submenu
                    described = openWith?.submenu?.items.map { item in
                        item.isSeparatorItem ? "—" : "\(item.title)\(item.image.map { " [icon \(Int($0.size.width))×\(Int($0.size.height))]" } ?? " [no icon]")"
                    } ?? ["no Open With item (menu: \(items.map(\.title)))"]
                    let timer = Timer(timeInterval: 0.3, repeats: false) { _ in MainActor.assumeIsolated { menu?.cancelTrackingWithoutAnimation() } }
                    RunLoop.main.add(timer, forMode: .eventTracking)
                }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            let rect = table.rect(ofRow: row)
            let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            if let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.postEvent(event, atStart: false)
            }
            try? await Task.sleep(for: .seconds(2))
            lines += described.isEmpty ? ["no menu opened"] : described
            // A picture: the same submenu shown on its own (the shell photographs
            // this copy's menu window when <log>.menu appears, then writes <log>.shot).
            if let submenu = UITestHarness.openWithSubmenu {
                let copy = submenu.copy() as! NSMenu
                Task { @MainActor in
                    for _ in 0..<60 where !fm.fileExists(atPath: logPath + ".shot") { try? await Task.sleep(for: .milliseconds(100)) }
                    copy.cancelTrackingWithoutAnimation()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    try? "ready".write(toFile: logPath + ".menu", atomically: true, encoding: .utf8)
                }
                copy.popUp(positioning: nil, at: NSPoint(x: 200, y: 400), in: window.contentView)
            }
            try? fm.removeItem(at: folder)
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
            // The window's columns (the sidebar first), as the split view lays them out.
            @MainActor func splitViews(_ view: NSView) -> [NSSplitView] {
                (view as? NSSplitView).map { [$0] } ?? view.subviews.flatMap(splitViews)
            }
            // A window without saved state (test copies ignore Blit's) starts
            // with the sidebar collapsed: its points are skipped then.
            let sidebarShown = window.contentView.map(splitViews)?.first?.arrangedSubviews.first?.isHidden == false

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
            // Where the list is: its first row, and space below the last.
            guard let table = fileLists(in: window).first, let scroll = table.enclosingScrollView else { return lines.append("no list") }
            let listFrame = scroll.convert(scroll.bounds, to: nil)
            let listX = listFrame.midX
            let firstRow = table.convert(NSPoint(x: table.rect(ofRow: 0).midX, y: table.rect(ofRow: 0).midY), to: nil)
            var points: [(String, NSPoint)] = [
                ("file row", NSPoint(x: listX, y: firstRow.y)),
                ("empty list space", NSPoint(x: listX, y: listFrame.minY + listFrame.height * 0.3)),
            ]
            if sidebarShown {
                points += [("sidebar upper", NSPoint(x: content.minX + 80, y: content.maxY - 60)),
                           ("sidebar middle", NSPoint(x: content.minX + 80, y: content.midY))]
            } else {
                lines.append("sidebar collapsed (no saved window state): its points skipped")
            }
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

#if DEBUG
/// A drag for the native drop test: where it is and what it carries.
@MainActor
final class StandInDrag: NSObject, @MainActor NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSequenceNumber: Int
    let draggingDestinationWindow: NSWindow?
    var location = NSPoint.zero

    init(pasteboard: NSPasteboard, sequence: Int, window: NSWindow) {
        draggingPasteboard = pasteboard
        draggingSequenceNumber = sequence
        draggingDestinationWindow = window
    }

    var draggingLocation: NSPoint { location }
    var draggingSourceOperationMask: NSDragOperation { [.copy, .move, .generic] }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
#endif
