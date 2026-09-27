// Pixel-art accents outside the HUD (PRD Visual language): used only for
// status and motion, never for the things you read or click. Everything is
// drawn on whole-point grids so edges stay crisp.

import AppKit
import SwiftUI

/// A 1-bit bitmap ("#" on, anything else off) as a crisp template image.
enum PixelArt {
    @MainActor private static var cache: [String: NSImage] = [:]

    @MainActor
    static func image(_ rows: [String], cell: CGFloat) -> NSImage {
        let key = rows.joined(separator: "/") + "@\(cell)"
        if let cached = cache[key] { return cached }
        let width = CGFloat(rows.map(\.count).max() ?? 0) * cell
        let height = CGFloat(rows.count) * cell
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            NSColor.black.setFill()
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    NSRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }

    /// The NAS-verification shield: a shield with a check knocked out.
    static let shield = [
        "#########",
        "#########",
        "#######.#",
        "######.##",
        "#.###.###",
        "##.#.####",
        ".##.####.",
        "..#####..",
        "....#....",
    ]

    /// Menu bar arrow into a tray, or (`up`: data leaving this Mac for a
    /// share) out of it. While transferring, the stem's dashes march the way
    /// the data goes (`frame` 0…2); idle, the stem is solid.
    static func menuBarArrow(frame: Int?, up: Bool = false) -> [String] {
        let head = [
            "#########",
            ".#######.",
            "..#####..",
            "...###...",
            "....#....",
        ]
        var stem: [String] = []
        for row in 0..<5 {
            let lit = frame.map { up ? (row + $0) % 3 != 2 : (row - $0 + 3) % 3 != 2 } ?? true
            stem.append(lit ? "...###..." : ".........")
        }
        let arrow = up ? head.reversed() + stem : stem + head
        return arrow + [".........", "#########"]
    }
}

/// A pixel spinner: one bright dot chasing around a 3×3 ring, with a fading tail.
struct PixelSpinner: View {
    /// Points per pixel.
    var cell: CGFloat = 1.5

    private static let ring = [(0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1)]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.09)) { context in
            let head = Int(context.date.timeIntervalSinceReferenceDate / 0.09) % Self.ring.count
            Canvas { gc, _ in
                for (index, (x, y)) in Self.ring.enumerated() {
                    let age = (head - index + Self.ring.count) % Self.ring.count
                    let opacity = age == 0 ? 1 : age == 1 ? 0.6 : age == 2 ? 0.3 : 0.12
                    let rect = CGRect(x: CGFloat(x) * cell * 2, y: CGFloat(y) * cell * 2, width: cell, height: cell)
                    gc.fill(Path(rect), with: .style(.primary.opacity(opacity)))
                }
            }
        }
        .frame(width: cell * 5, height: cell * 5)
        .accessibilityLabel("Loading")
    }
}

/// A drop-target outline as pixel "marching ants" stepping around the edge.
struct PixelMarchingAnts: View {
    var cell: CGFloat = 2
    var inset: CGFloat = 0

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.12)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate / 0.12) % 4
            Canvas { gc, size in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
                let columns = max(2, Int(rect.width / cell))
                let rows = max(2, Int(rect.height / cell))
                // Walk the perimeter clockwise, two cells on, two off.
                var cells: [(Int, Int)] = []
                cells += (0..<columns).map { ($0, 0) }
                cells += (1..<rows).map { (columns - 1, $0) }
                cells += (0..<(columns - 1)).reversed().map { ($0, rows - 1) }
                cells += (1..<(rows - 1)).reversed().map { (0, $0) }
                for (index, (x, y)) in cells.enumerated() where (index + 4 - phase) % 4 < 2 {
                    gc.fill(Path(CGRect(x: rect.minX + CGFloat(x) * cell, y: rect.minY + CGFloat(y) * cell,
                                        width: cell, height: cell)),
                            with: .style(.primary))
                }
            }
        }
        .allowsHitTesting(false)
    }
}
