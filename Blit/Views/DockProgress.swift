// Dock icon progress (PRD Visual language): while transferring, the icon gets
// a strip of pixel progress cells like the HUD's. When the queue finishes, a
// pixel ✓ (all verified) or a muted-red ✕ (problems) stays on the icon until
// you come back to Blit, so it's there when you return to the Mac.

import AppKit

@MainActor
final class DockProgress {
    static let shared = DockProgress()
    private let view = DockTileView()
    private var clearTask: Task<Void, Never>?
    private var activeObserver: NSObjectProtocol?

    enum Outcome { case verified, failed, plain }

    init() {
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.acknowledge() }
        }
    }

    /// Back in Blit: the result has been seen; clear it shortly.
    private func acknowledge() {
        guard view.badge != nil, view.progress == nil else { return }
        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            clear()
        }
    }

    /// Shows `fraction` (0…1) of the current transfer.
    func update(_ fraction: Double) {
        clearTask?.cancel()
        view.progress = max(0, min(1, fraction))
        view.badge = nil
        show()
    }

    /// The queue drained. ✓ or ✕ stays until you're back in Blit (a few
    /// seconds if you already are); otherwise back to the plain icon.
    func finish(_ outcome: Outcome) {
        clearTask?.cancel()
        view.progress = nil
        switch outcome {
        case .plain: return clear()
        case .verified: view.badge = .check
        case .failed: view.badge = .cross
        }
        show()
        if NSApp.isActive {
            clearTask = Task {
                try? await Task.sleep(for: .seconds(outcome == .failed ? 15 : 5))
                guard !Task.isCancelled else { return }
                clear()
            }
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
        view.badge = nil
        NSApp.dockTile.contentView = nil
        NSApp.dockTile.display()
    }
}

private final class DockTileView: NSView {
    var progress: Double?
    var badge: PixelGlyph?

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
        if let badge {
            let box = NSRect(x: bounds.width - 46 * unit, y: 6 * unit, width: 40 * unit, height: 40 * unit)
            (badge == .cross ? NSColor(red: 0xB3 / 255, green: 0x5C / 255, blue: 0x5C / 255, alpha: 1)
                             : NSColor(white: 0.04, alpha: 0.95)).setFill()
            NSBezierPath(roundedRect: box, xRadius: 6 * unit, yRadius: 6 * unit).fill()
            let rows = badge.rows
            let px = (4 * unit).rounded(.down)
            (badge == .cross ? NSColor(red: 0x1C / 255, green: 0x0E / 255, blue: 0x0E / 255, alpha: 1)
                             : NSColor(white: 0.94, alpha: 1)).setFill()
            for (y, row) in rows.enumerated() {
                for (x, ch) in row.enumerated() where ch == "#" {
                    NSRect(x: box.minX + 6 * unit + CGFloat(x) * px,
                           y: box.maxY - 6 * unit - CGFloat(y + 1) * px, width: px, height: px).fill()
                }
            }
        }
    }
}
