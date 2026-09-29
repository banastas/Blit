// Presses keys for Blit's UI tests (TwoPaneTest), only into an isolated test
// copy. Needs Accessibility for the process that runs it.
// Usage: ui-keys <log> <count> <test copy pid>. It first clicks the point in
// <log>.click ([x, y], CG coordinates, inside the test window) to bring the
// test copy forward, and before every key checks that the test copy is the
// frontmost app, stopping if not (keys must never land in another app).
// For step N it waits for <log>.keys-N ([keyCode, command 0/1], optionally
// followed by [x, y] to click first, e.g. to select a row), presses the key,
// then touches <log>.sent-N.
import AppKit
import CoreGraphics
import Foundation

let log = CommandLine.arguments[1]
let count = Int(CommandLine.arguments[2]) ?? 1
let pid = pid_t(CommandLine.arguments[3]) ?? -1
let fm = FileManager.default

func waitFor(_ path: String, _ seconds: Double) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if fm.fileExists(atPath: path) { return true }
        usleep(100_000)
    }
    return false
}

func mouse(_ type: CGEventType, _ p: CGPoint) {
    CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
}

func testCopyIsFrontmost() -> Bool { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }

guard waitFor(log + ".click", 40), let data = fm.contents(atPath: log + ".click"),
      let c = try? JSONSerialization.jsonObject(with: data) as? [Double], c.count == 2 else { print("no click point"); exit(1) }
let point = CGPoint(x: c[0], y: c[1])
mouse(.mouseMoved, point); usleep(150_000)
mouse(.leftMouseDown, point); usleep(80_000)
mouse(.leftMouseUp, point); usleep(500_000)
fm.createFile(atPath: log + ".clicked", contents: nil)

for index in 0..<count {
    guard waitFor(log + ".keys-\(index)", 40), let data = fm.contents(atPath: log + ".keys-\(index)"),
          let k = try? JSONSerialization.jsonObject(with: data) as? [Int], k.count >= 2 else { print("no key \(index)"); exit(1) }
    if k.count == 4 {
        let target = CGPoint(x: k[2], y: k[3])
        mouse(.mouseMoved, target); usleep(150_000)
        mouse(.leftMouseDown, target); usleep(80_000)
        mouse(.leftMouseUp, target); usleep(700_000)
        if let wid = try? String(contentsOfFile: log + ".wid", encoding: .utf8) {
            let shot = Process()
            shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            shot.arguments = ["-x", "-o", "-l", wid.trimmingCharacters(in: .whitespacesAndNewlines), log + "-click-\(index).png"]
            try? shot.run()
            shot.waitUntilExit()
        }
    }
    guard testCopyIsFrontmost() else {
        print("test copy isn't frontmost; stopping before key \(index + 1)")
        fm.createFile(atPath: log + ".aborted", contents: nil)
        exit(2)
    }
    let flags: CGEventFlags = k[1] == 1 ? .maskCommand : []
    for down in [true, false] {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(k[0]), keyDown: down)
        event?.flags = flags
        event?.post(tap: .cghidEventTap)
        usleep(60_000)
    }
    fm.createFile(atPath: log + ".sent-\(index)", contents: nil)
    print("key \(index + 1) sent")
}
