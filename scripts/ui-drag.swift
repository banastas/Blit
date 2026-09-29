// Posts real mouse drags for Blit's UI tests (DropTest, SidebarDropTest,
// DragOutTest), only into an isolated test copy's window. Needs Accessibility
// for the process that runs it. Usage: ui-drag <log> <count>. For each drag N
// it waits for <log>.points-N ([fromX, fromY, toX, toY], CG coordinates),
// drags, touches <log>.hover-N while hovering (and photographs the test
// window if <log>.wid holds its number), then releases.
import CoreGraphics
import Foundation

let log = CommandLine.arguments[1]
let count = Int(CommandLine.arguments[2]) ?? 1
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
    post(.mouseMoved, from); usleep(200_000)
    post(.leftMouseDown, from); usleep(250_000)
    let steps = 30
    for i in 1...steps {
        let t = Double(i) / Double(steps)
        post(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * t + (i < steps ? 3 : 0), y: from.y + (to.y - from.y) * t))
        usleep(25_000)
    }
    post(.leftMouseDragged, to); usleep(600_000)
    fm.createFile(atPath: log + ".hover-\(index)", contents: nil)
    if let wid = try? String(contentsOfFile: log + ".wid", encoding: .utf8) {
        let shot = Process()
        shot.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        shot.arguments = ["-x", "-o", "-l", wid.trimmingCharacters(in: .whitespacesAndNewlines), log + "-screen-\(index).png"]
        try? shot.run()
        shot.waitUntilExit()
    }
    usleep(900_000)
    post(.leftMouseUp, to)
    print("drag \(index + 1) posted")
}
