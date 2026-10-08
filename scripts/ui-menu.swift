// Real right-clicks and menu picks for Blit's UI tests (MenuRenameTest), only
// into an isolated test copy. Needs Accessibility for the process that runs
// it. Usage: ui-menu <log> <count> <test copy pid>. For step N it waits for
// <log>.rclick-N ({"x", "y" (CG coordinates), "item": a menu item's title}),
// brings the test copy forward, right-clicks there as a trackpad's two-finger
// click does (button down and up at once), finds the item in the menu that
// opened and clicks it, then touches <log>.chosen-N (or <log>.missed-N). Every
// click first checks that the window under the pointer is the test copy's:
// never into another app the user has in front.
import ApplicationServices
import CoreGraphics
import Foundation

let log = CommandLine.arguments[1]
let count = Int(CommandLine.arguments[2]) ?? 1
guard CommandLine.arguments.count > 3, let pid = pid_t(CommandLine.arguments[3]) else {
    print("usage: ui-menu <log> <count> <test copy pid>"); exit(64)
}
let fm = FileManager.default

func waitFor(_ path: String, _ seconds: Double) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if fm.fileExists(atPath: path) { return true }
        usleep(100_000)
    }
    return false
}

func post(_ type: CGEventType, _ point: CGPoint, button: CGMouseButton) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)?.post(tap: .cghidEventTap)
}

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

/// Whether the frontmost window under `point` (any layer: menus too) is the
/// test copy's.
func testCopyOwnsPoint(_ point: CGPoint, pid: pid_t) -> Bool {
    let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    for window in windows {   // front to back
        guard let bounds = window[kCGWindowBounds as String] as? [String: Double],
              let alpha = window[kCGWindowAlpha as String] as? Double, alpha > 0,
              let layer = window[kCGWindowLayer as String] as? Int, layer < 1000 else { continue }
        let frame = CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
        guard frame.contains(point) else { continue }
        return (window[kCGWindowOwnerPID as String] as? Int).map { pid_t($0) } == pid
    }
    return false
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

/// The open menu's item titled `title`, and where its middle is (CG
/// coordinates). A context menu isn't among the app's own elements: it's found
/// by what's on screen beside the click that opened it (any corner, as it opens
/// up or to the left near the screen's edges).
func menuItem(_ title: String, near click: CGPoint, in pid: pid_t) -> CGPoint? {
    let system = AXUIElementCreateSystemWide()
    for (dx, dy) in [(30.0, 12.0), (-30.0, 12.0), (30.0, -12.0), (-30.0, -12.0)] {
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(click.x + dx), Float(click.y + dy), &found) == .success,
              var element = found else { continue }
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success, owner == pid else { continue }
        // Up to the menu.
        for _ in 0..<4 where attribute(element, kAXRoleAttribute) as? String != kAXMenuRole {
            guard let parent = attribute(element, kAXParentAttribute) else { break }
            element = parent as! AXUIElement
        }
        guard attribute(element, kAXRoleAttribute) as? String == kAXMenuRole else { continue }
        for item in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        where attribute(item, kAXTitleAttribute) as? String == title {
            var position = CGPoint.zero, size = CGSize.zero
            guard let p = attribute(item, kAXPositionAttribute), let s = attribute(item, kAXSizeAttribute),
                  AXValueGetValue(p as! AXValue, .cgPoint, &position), AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
            return CGPoint(x: position.x + min(40, size.width / 2), y: position.y + size.height / 2)
        }
    }
    return nil
}

/// --dump: what Accessibility sees of the app when the item isn't found.
func dump(_ element: AXUIElement, depth: Int) {
    guard depth < 4 else { return }
    let role = attribute(element, kAXRoleAttribute) as? String ?? "?"
    let title = attribute(element, kAXTitleAttribute) as? String ?? ""
    print(String(repeating: "  ", count: depth) + role + (title.isEmpty ? "" : " “\(title)”"))
    for child in (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(30) { dump(child, depth: depth + 1) }
}

for index in 0..<count {
    guard waitFor(log + ".rclick-\(index)", 60), let data = fm.contents(atPath: log + ".rclick-\(index)"),
          let step = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let x = step["x"] as? Double, let y = step["y"] as? Double, let title = step["item"] as? String else {
        print("no step \(index)"); exit(1)
    }
    let point = CGPoint(x: x, y: y)
    // Raising can take a moment (the copy may still be activating).
    for _ in 0..<6 where !testCopyOwnsPoint(point, pid: pid) { bringForward(pid) }
    guard testCopyOwnsPoint(point, pid: pid) else {
        print("the test copy's window isn't the one under the pointer; stopping before step \(index + 1)")
        fm.createFile(atPath: log + ".aborted", contents: nil)
        exit(2)
    }
    post(.mouseMoved, point, button: .left); usleep(150_000)
    post(.rightMouseDown, point, button: .right); usleep(40_000)
    post(.rightMouseUp, point, button: .right)
    var item: CGPoint?
    for _ in 0..<20 where item == nil {
        usleep(100_000)
        item = menuItem(title, near: point, in: pid)
    }
    guard let item, testCopyOwnsPoint(item, pid: pid) else {
        print("no “\(title)” in a menu of the test copy at step \(index + 1) (found at \(item.map { "\($0)" } ?? "nowhere"))")
        if CommandLine.arguments.contains("--dump") { dump(AXUIElementCreateApplication(pid), depth: 0) }
        fm.createFile(atPath: log + ".missed-\(index)", contents: nil)
        continue
    }
    post(.mouseMoved, item, button: .left); usleep(250_000)
    post(.leftMouseDown, item, button: .left); usleep(60_000)
    post(.leftMouseUp, item, button: .left)
    fm.createFile(atPath: log + ".chosen-\(index)", contents: nil)
}
