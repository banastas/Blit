// Pixel glyphs for the HUD. Silkscreen and VT323 have no ✓ ✕ ▲ ▼ →, so the
// system would draw smooth fallback glyphs; these 7×7 bitmaps keep the HUD
// on its 1-bit grid. Rendered as template images inline with Text.

import AppKit
import SwiftUI

enum PixelGlyph: Character, CaseIterable {
    case check = "✓", cross = "✕", up = "▲", down = "▼", arrow = "→"

    var rows: [String] {
        switch self {
        case .check: [".......", "......#", ".....#.", "#...#..", ".#.#...", "..#....", "......."]
        case .cross: ["#.....#", ".#...#.", "..#.#..", "...#...", "..#.#..", ".#...#.", "#.....#"]
        case .up:    [".......", "...#...", "..###..", ".#####.", "#######", ".......", "......."]
        case .down:  [".......", ".......", "#######", ".#####.", "..###..", "...#...", "......."]
        case .arrow: [".......", "....#..", ".....#.", "#######", ".....#.", "....#..", "......."]
        }
    }

    /// A template image `size` points tall (whole pixels per cell, so edges stay crisp).
    @MainActor
    func image(size: CGFloat) -> NSImage {
        let key = "\(rawValue)@\(size)"
        if let cached = Self.cache[key] { return cached }
        let cell = max(1, (size / 7).rounded(.down))
        let side = cell * 7
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            NSColor.black.setFill()
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    NSRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        Self.cache[key] = image
        return image
    }

    @MainActor private static var cache: [String: NSImage] = [:]
}

/// HUD text with ✓ ✕ ▲ ▼ → drawn as pixel glyphs; everything else as text.
@MainActor
func hudText(_ string: String, glyphSize: CGFloat = 11) -> Text {
    var result = Text(verbatim: "")
    var run = ""
    for ch in string {
        if let glyph = PixelGlyph(rawValue: ch) {
            if !run.isEmpty { result = Text("\(result)\(Text(verbatim: run))"); run = "" }
            result = Text("\(result)\(Text(Image(nsImage: glyph.image(size: glyphSize))).baselineOffset(-1))")
        } else {
            run.append(ch)
        }
    }
    if !run.isEmpty { result = Text("\(result)\(Text(verbatim: run))") }
    return result
}
