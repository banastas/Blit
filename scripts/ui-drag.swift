// Posts real mouse drags for Blit's UI tests (DropTest, SidebarDropTest,
// DragOutTest), only into an isolated test copy's window. Needs Accessibility
// for the process that runs it. Usage: ui-drag <log> <count> <test copy pid>
// [--allow-end-outside] (DragOutTest ends its drag over Finder) [--straight]
// (no sideways wiggle, for a drag that selects rows). Before each
// drag it checks that the test copy's window is the one under the start point
// (and the end point, unless allowed), and stops if not: never into another
// app the user has in front. For each drag N
// it waits for <log>.points-N ([fromX, fromY, toX, toY], CG coordinates),
// drags, touches <log>.hover-N while hovering (and photographs the test
// window if <log>.wid holds its number), then releases.
import ApplicationServices
import CoreGraphics
import Foundation

let log = CommandLine.arguments[1]
let count = Int(CommandLine.arguments[2]) ?? 1
guard CommandLine.arguments.count > 3, let pid = pid_t(CommandLine.arguments[3]) else {
    print("usage: ui-drag <log> <count> <test copy pid> [--allow-end-outside]"); exit(64)
}
let endMayBeOutside = CommandLine.arguments.contains("--allow-end-outside")
/// --straight: no sideways wiggle (it helps file drags start; a drag meant to
/// select rows moves straight down, as a person's would).
let straight = CommandLine.arguments.contains("--straight")
/// --fast: a quick flick, as a person drags (tests drag slowly; the user's
/// drags that froze Blit lasted 78–650 ms): 6 steps, released at once.
let fast = CommandLine.arguments.contains("--fast")
let fm = FileManager.default

func waitFor(_ path: String, _ seconds: Double) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if fm.fileExists(atPath: path) { return true }
        usleep(100_000)
    }
    return false
}

func post(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

for index in 0..<count {
    guard waitFor(log + ".points-\(index)", 40), let data = fm.contents(atPath: log + ".points-\(index)"),
          let d = try? JSONSerialization.jsonObject(with: data) as? [Double] else { print("no points \(index)"); exit(1) }
    let from = CGPoint(x: d[0], y: d[1]), to = CGPoint(x: d[2], y: d[3])
    // A copy launched from a script can't always take focus from the app in
    // use; bring it forward (it's still checked below, as ever).
    if !testCopyOwnsPoint(from, pid: pid) { bringForward(pid) }
    guard testCopyOwnsPoint(from, pid: pid), endMayBeOutside || testCopyOwnsPoint(to, pid: pid) else {
        print("the test copy's window isn't the one under the pointer; stopping before drag \(index + 1)")
        fm.createFile(atPath: log + ".aborted", contents: nil)
        exit(2)
    }
    post(.mouseMoved, from); usleep(200_000)
    post(.leftMouseDown, from); usleep(fast ? 60_000 : 250_000)
    let steps = fast ? 6 : 30
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t + (i < steps && !straight ? 3 : 0), y: from.y + (to.y - from.y) * t))
        usleep(fast ? 15_000 : 25_000)
    }
    post(.leftMouseDragged, to); usleep(fast ? 40_000 : 600_000)
    fm.createFile(atPath: log + ".hover-\(index)", contents: nil)
    if !fast, let wid = try? String(contentsOfFile: log + ".wid", encoding: .utf8) {
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-o", "-l", wid.trimmingCharacters(in: .whitespacesAndNewlines), log + "-screen-\(index).png"]
        try? shot.run()
        shot.waitUntilExit()
    }
    if !fast { usleep(900_000) }
    post(.leftMouseUp, to)
    print("drag \(index + 1) posted")
}

/// Brings the test copy and its window in front, through Accessibility (which
/// this helper has, to post events).
func bringForward(_ pid: pid_t) {
    let app = AXUIElementCreateApplication(pid)
    AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
    var windows: CFTypeRef?
    if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
       let window = (windows as? [AXUIElement])?.first {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
    usleep(500_000)
}

/// Whether the frontmost window under `point` (CG coordinates) belongs to the
/// test copy. Every synthetic click or drag checks this first: with another
/// app's window on top, the event would land in that app instead.
func testCopyOwnsPoint(_ point: CGPoint, pid: pid_t) -> Bool {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in windows {   // front to back
        guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
              let bounds = window[kCGWindowBounds as String] as? [String: Double],
              let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0 else { continue }
        let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        guard frame.contains(point) else { continue }
        return (window[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) } == pid
    }
    return false
}
