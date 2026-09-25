// Dock icon progress (PRD Visual language): while transferring, the icon gets
// a strip of pixel progress cells like the HUD's; a pixel ✓ shows briefly
// when a batch finishes verified.

import AppKit

@MainActor
final class DockProgress {
    static let shared = DockProgress()
    private let view = DockTileView()
    private var clearTask: Task<Void, Never>?

    /// Shows `fraction` (0…1) of the current transfer.
    func update(_ fraction: Double) {
        clearTask?.cancel()
        view.progress = max(0, min(1, fraction))
        view.done = false
        show()
    }

    /// The batch ended: a ✓ for a few seconds if it all verified, else back to the plain icon.
    func finish(verified: Bool) {
        clearTask?.cancel()
        guard verified else { return clear() }
        view.progress = nil
        view.done = true
        show()
        clearTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            clear()
        }
    }

    private func show() {
        let tile = NSApp.dockTile
        if tile.contentView !== view {
            view.frame = NSRect(origin: .zero, size: tile.size)
            tile.contentView = view
        }
        view.needsDisplay = true
        tile.display()
    }

    private func clear() {
        view.progress = nil
        view.done = false
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }
}

private final class DockTileView: NSView {
    var progress: Double?
    var done = false

    override func draw(_ dirtyRect: NSRect) {
        NSApp.applicationIconImage?.draw(in: bounds)
        let unit = bounds.width / 128   // design on a 128-pt grid
        if let progress {
            let cells = 10
            let cell = (6 * unit).rounded(.down)
            let gap = (2 * unit).rounded(.down)
            let width = CGFloat(cells) * cell + CGFloat(cells - 1) * gap
            let bar = NSRect(x: (bounds.width - width) / 2 - 4 * unit, y: 17 * unit,
                             width: width + 8 * unit, height: cell + 8 * unit)
            NSColor(white: 0.04, alpha: 0.92).setFill()
            NSBezierPath(roundedRect: bar, xRadius: 3 * unit, yRadius: 3 * unit).fill()
            let lit = Int((progress * Double(cells)).rounded(.down))
            for i in 0..<cells {
                (i < lit ? NSColor(white: 0.94, alpha: 1) : NSColor(white: 0.2, alpha: 1)).setFill()
                NSRect(x: bar.minX + 4 * unit + CGFloat(i) * (cell + gap), y: bar.minY + 4 * unit,
                       width: cell, height: cell).fill()
            }
        }
        if done {
            let box = NSRect(x: bounds.width - 46 * unit, y: 6 * unit, width: 40 * unit, height: 40 * unit)
            NSColor(white: 0.04, alpha: 0.95).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6 * unit, yRadius: 6 * unit).fill()
            let rows = PixelGlyph.check.rows
            let px = (4 * unit).rounded(.down)
            NSColor(white: 0.94, alpha: 1).setFill()
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    NSRect(x: box.minX + 6 * unit + CGFloat(x) * px,
                           y: box.maxY - 6 * unit - CGFloat(y + 1) * px, width: px, height: px).fill()
                }
            }
        }
    }
}
