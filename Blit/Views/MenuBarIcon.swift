// The menu bar item, drawn as one template image of a fixed width so it never
// nudges its neighbours as the numbers change. One running lane: the pixel
// arrow (its tray filling with progress) and time left. Both lanes: two small
// lines, one per lane, each with its own arrow.

import AppKit

@MainActor
enum MenuBarIcon {
    /// One lane's readout.
    struct Line: Equatable {
        /// Data leaving this Mac (a copy onto a share): the arrow points up.
        var up: Bool
        /// Only checksums remain: the shield instead of the arrow.
        var verifying: Bool
        /// Fills the tray under the arrow (one lane only); nil leaves it solid.
        var progress: Double?
        /// Time left, a percentage, or a short state ("···" retrying).
        var text: String
    }

    private static let cell: CGFloat = 1.5
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
    private static let smallFont = NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .medium)
    /// Every string a slot can hold is measured, and the slot takes the widest.
    private static let samples = ["0h00", "00h", ">99h", "100%", "<1m", "00m", "···", "full", "--", "‖"]

    private static func slotWidth(_ font: NSFont) -> CGFloat {
        samples.map { ($0 as NSString).size(withAttributes: [.font: font]).width }.max()!.rounded(.up)
    }

    /// "<1m", "12m", "1h05", "14h": short enough for the slot, and coarse
    /// enough not to flicker.
    static func time(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "<1m" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 36_000 { return String(format: "%dh%02d", s / 3600, s % 3600 / 60) }
        if s < 360_000 { return "\(s / 3600)h" }
        return ">99h"
    }

    static func image(_ lines: [Line], frame: Int?) -> NSImage {
        lines.count == 1 ? single(lines[0], frame: frame) : stacked(Array(lines.prefix(2)), frame: frame)
    }

    private static func single(_ line: Line, frame: Int?) -> NSImage {
        let rows = line.verifying ? PixelArt.shield : PixelArt.menuBarArrow(frame: frame, up: line.up, progress: line.progress)
        let iconWidth = (CGFloat(rows[0].count) * cell).rounded(.up)
        let iconHeight = CGFloat(rows.count) * cell
        let height: CGFloat = 18
        let image = NSImage(size: NSSize(width: iconWidth + 4 + slotWidth(font), height: height), flipped: true) { _ in
            PixelArt.draw(rows, cell: cell, at: NSPoint(x: 0, y: ((height - iconHeight) / 2).rounded()))
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let size = (line.text as NSString).size(withAttributes: attributes)
            (line.text as NSString).draw(at: NSPoint(x: iconWidth + 4, y: (height - size.height) / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Small arrows (5×4) for the stacked lines; the dashes march with `frame`.
    private static func mini(up: Bool, verifying: Bool, frame: Int?) -> [String] {
        if verifying { return ["....#", "...#.", "#.#..", ".#..."] }   // a check: checksums running
        let head = ["..#..", ".###.", "#####"]
        let stem = frame.map { $0 % 2 == 0 } ?? true ? "..#.." : "....."
        return up ? head + [stem] : [stem] + head.reversed()
    }

    private static func stacked(_ lines: [Line], frame: Int?) -> NSImage {
        let lineHeight: CGFloat = 10
        let height = lineHeight * 2
        let glyphWidth = 5 * cell
        let image = NSImage(size: NSSize(width: glyphWidth + 3 + slotWidth(smallFont), height: height), flipped: true) { _ in
            let attributes: [NSAttributedString.Key: Any] = [.font: smallFont, .foregroundColor: NSColor.black]
            for (index, line) in lines.enumerated() {
                let top = CGFloat(index) * lineHeight
                PixelArt.draw(mini(up: line.up, verifying: line.verifying, frame: frame), cell: cell,
                              at: NSPoint(x: 0, y: top + ((lineHeight - 4 * cell) / 2).rounded()))
                let size = (line.text as NSString).size(withAttributes: attributes)
                (line.text as NSString).draw(at: NSPoint(x: glyphWidth + 3, y: top + (lineHeight - size.height) / 2),
                                             withAttributes: attributes)
            }
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Idle, paused (a ‖ in the slot, so the width holds while work is held),
    /// and finished (a check over the tray, for a minute).
    static let idle = PixelArt.image(PixelArt.menuBarArrow(frame: nil), cell: 1.5)
    static let done = PixelArt.image(PixelArt.menuBarCheck, cell: 1.5)
    static var paused: NSImage { single(Line(up: false, verifying: false, progress: nil, text: "‖"), frame: nil) }

    /// A small ✕ in the failure red, beside the icon until the panel is opened.
    /// Not a template: it keeps its colour on light and dark menu bars.
    static let failureMark: NSImage = {
        let rows = ["#...#", ".#.#.", "..#..", ".#.#.", "#...#"]
        let image = NSImage(size: NSSize(width: 5 * cell, height: 18), flipped: true) { _ in
            NSColor(red: 0xB3 / 255, green: 0x5C / 255, blue: 0x5C / 255, alpha: 1).setFill()
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    NSRect(x: CGFloat(x) * cell, y: 5 + CGFloat(y) * cell, width: cell, height: cell).fill()
                }
            }
            return true
        }
        image.isTemplate = false
        return image
    }()
}
