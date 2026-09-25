// Debug builds only: a self-test for right-click menus, since they can't be
// checked from outside the app without Accessibility access. Launch with
// `-BlitRightClickTest /path/to/log.txt`: Blit opens a small temporary folder,
// sends itself right-clicks at a few points, writes which menu opened at each
// (or none), then goes back.

#if DEBUG
import AppKit

@MainActor
enum UITestHarness {
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
            browser.open(.local(folder))
            try? await Task.sleep(for: .seconds(1.5))
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
            browser.goBack()
        }
    }
}
#endif
