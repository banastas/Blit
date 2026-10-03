// The AppKit file list's cells (PRD R2.6). Each cell is one view that draws
// its text, icon and glyphs itself: every view in the list costs time on each
// SwiftUI update (it walks them all) and memory, and labels and image views
// came to five or more a cell. Values are set only when they change.

import AppKit
import BlitRemote

/// What every cell of one pass shares: the pane's model and the list's state.
@MainActor
struct CellContext {
    let browser: BrowserModel
    /// Which of DateForms' forms the Modified column has room for.
    let dateLevel: Int
    /// With the Status column hidden (the default), the status is a tag after the name.
    let statusAfterName: Bool
}

/// The list's fonts: the SwiftUI list's body font, with even digits where
/// numbers line up.
@MainActor
enum CellFonts {
    static let body = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    static let digits = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    static let caption = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
}

/// Drawing helpers shared by the cells.
@MainActor
enum CellDrawing {
    /// One line of `text` in `rect` (vertically centred), cut short as `lineBreak` says.
    static func draw(_ text: String, in rect: NSRect, font: NSFont, color: NSColor,
                     alignment: NSTextAlignment = .left, lineBreak: NSLineBreakMode = .byTruncatingTail) {
        guard !text.isEmpty, rect.width > 1 else { return }
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        style.lineBreakMode = lineBreak
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let height = lineHeight(font)
        let line = NSRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        (text as NSString).draw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)
    }

    static func width(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    static func lineHeight(_ font: NSFont) -> CGFloat { ceil(font.ascender - font.descender + font.leading) }

    /// A template image (pixel glyphs, symbols) in one colour.
    static func draw(template image: NSImage, in rect: NSRect, color: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext,
              let cgImage = image.cgImage(forProposedRect: nil, context: NSGraphicsContext.current, hints: nil) else { return }
        context.saveGState()
        // A mask is drawn with the context's own orientation: flip it back in flipped views.
        if NSGraphicsContext.current?.isFlipped == true {
            context.translateBy(x: 0, y: rect.minY + rect.maxY)
            context.scaleBy(x: 1, y: -1)
        }
        context.clip(to: rect, mask: cgImage)
        context.setFillColor(color.cgColor)
        context.fill(rect)
        context.restoreGState()
    }
}

/// A transfer's status for a row: a pixel glyph (or "=") and a word, never
/// colour alone; muted red only for failures.
@MainActor
struct StatusDrawing {
    let status: FileStatus
    let font: NSFont

    private var pixel: PixelGlyph? { status.glyph.flatMap(PixelGlyph.init(rawValue:)) }
    private var text: String { pixel == nil ? (status.glyph.map { "\($0) \(status.text)" } ?? status.text) : status.text }

    var width: CGFloat { (pixel == nil ? 0 : 9 + 4) + CellDrawing.width(text, font: font) }

    func draw(in rect: NSRect, emphasized: Bool) {
        let color: NSColor = emphasized ? .alternateSelectedControlTextColor : (status.isFailure ? .failureText : .secondaryLabelColor)
        var x = rect.minX
        if let pixel {
            CellDrawing.draw(template: pixel.image(size: 9), in: NSRect(x: x, y: (rect.midY - 4.5).rounded(), width: 9, height: 9), color: color)
            x += 13
        }
        CellDrawing.draw(text, in: NSRect(x: x, y: rect.minY, width: rect.maxX - x, height: rect.height), font: font, color: color)
    }
}

/// The base for the list's cells: drawn by itself, flipped, with the row's
/// selection look.
class DrawnCellView: NSTableCellView {
    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var wantsUpdateLayer: Bool { false }

    /// White on an emphasized (blue) selection.
    var emphasized: Bool { backgroundStyle == .emphasized }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { if backgroundStyle != oldValue { needsDisplay = true } }
    }
}

/// The Name column: indent, disclosure triangle, icon, the name (shortened in
/// the middle, so a release's year, group and extension stay in view), then
/// the ✓ verified and ◐ partial glyphs and the status tag.
final class NameCellView: DrawnCellView {
    private(set) var item: FileItem?
    private var icon: NSImage?
    private var isExpanded = false
    private var verifiedHelp: String?
    private var partialHelp: String?
    private var status: FileStatus?
    /// The disclosure triangle was clicked.
    var onToggle: ((FileItem) -> Void)?
    /// Where each part was drawn, for tooltips and the drag rule.
    private(set) var nameRect = NSRect.zero
    private(set) var iconRect = NSRect.zero
    private var disclosureRect = NSRect.zero
    private var verifiedRect = NSRect.zero
    private var partialRect = NSRect.zero
    private var statusRect = NSRect.zero
    private var nameTruncated = false

    private static let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))
    private static let chevronDown = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .bold))


    func configure(_ item: FileItem, context: CellContext) {
        let browser = context.browser
        let entry = item.isDirectory ? nil : item.location.localURL.flatMap { VerifiedIndex.shared.entry(for: $0, size: item.size) }
        let verifiedHelp = entry?.summary
        let partialHelp = item.partial.map(browser.partialSummary)
        let status = context.statusAfterName ? browser.operations.transfers.status(for: item) : nil
        let expanded = item.isDirectory && browser.expanded.contains(item.location)
        let changed = item != self.item || verifiedHelp != self.verifiedHelp || partialHelp != self.partialHelp
            || status != self.status || expanded != isExpanded
        if item.id != self.item?.id || icon == nil { icon = IconCache.shared.rowIcon(for: item) }
        self.item = item
        self.verifiedHelp = verifiedHelp
        self.partialHelp = partialHelp
        self.status = status
        isExpanded = expanded
        if changed {
            setAccessibilityLabel(([item.name] + [entry == nil ? nil : "Verified", item.partial == nil ? nil : "Partial download",
                                                  status.map { "Status: \($0.text)" }].compactMap { $0 }).joined(separator: ", "))
            needsLayout = true
            needsDisplay = true
        }
    }

    // The disclosure triangle takes its own clicks (the row isn't selected), as a button would.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard item?.isDirectory == true, let superview else { return super.hitTest(point) }
        return disclosureRect.insetBy(dx: -2, dy: -4).contains(convert(point, from: superview)) ? self : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let item, item.isDirectory, disclosureRect.insetBy(dx: -2, dy: -4).contains(point) {
            onToggle?(item)
        } else {
            super.mouseDown(with: event)
        }
    }

    /// Lays the parts out (the name gives up width before the glyphs do).
    override func layout() {
        super.layout()
        guard let item else { return }
        let height = bounds.height
        func centered(_ size: CGFloat) -> CGFloat { ((height - size) / 2).rounded() }
        var x = CGFloat(item.depth) * 16 + (item.depth > 0 ? 4 : 0)
        disclosureRect = item.isDirectory ? NSRect(x: x, y: centered(16), width: 12, height: 16) : .zero
        x += 12 + 4
        iconRect = NSRect(x: x, y: centered(16), width: 16, height: 16)
        x += 16 + 6
        let statusWidth: CGFloat = status.map { StatusDrawing(status: $0, font: CellFonts.caption).width } ?? 0
        var trailing: CGFloat = 0
        if verifiedHelp != nil { trailing += 5 + 9 }
        if partialHelp != nil { trailing += 5 + 9 }
        if status != nil { trailing += 5 + statusWidth }
        let natural = CellDrawing.width(item.name, font: CellFonts.body)
        let nameWidth = max(0, min(natural, bounds.width - x - trailing))
        nameTruncated = nameWidth < natural
        nameRect = NSRect(x: x, y: 0, width: nameWidth, height: height)
        x += nameWidth
        verifiedRect = .zero
        partialRect = .zero
        statusRect = .zero
        if verifiedHelp != nil {
            verifiedRect = NSRect(x: x + 5, y: centered(9), width: 9, height: 9)
            x += 5 + 9
        }
        if partialHelp != nil {
            partialRect = NSRect(x: x + 5, y: centered(9), width: 9, height: 9)
            x += 5 + 9
        }
        if status != nil {
            statusRect = NSRect(x: x + 5, y: 0, width: statusWidth, height: height)
        }
        removeAllToolTips()
        if disclosureRect != .zero { addToolTip(disclosureRect, owner: self, userData: nil) }
        if nameTruncated { addToolTip(nameRect, owner: self, userData: nil) }
        for rect in [verifiedRect, partialRect, statusRect] where rect != .zero { addToolTip(rect, owner: self, userData: nil) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let glyphColor: NSColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        if disclosureRect != .zero, let chevron = isExpanded ? Self.chevronDown : Self.chevron {
            let size = chevron.size
            let rect = NSRect(x: disclosureRect.midX - size.width / 2, y: disclosureRect.midY - size.height / 2,
                              width: size.width, height: size.height).integral
            CellDrawing.draw(template: chevron, in: rect, color: glyphColor)
        }
        icon?.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        CellDrawing.draw(item.name, in: nameRect, font: CellFonts.body,
                         color: emphasized ? .alternateSelectedControlTextColor : .labelColor, lineBreak: .byTruncatingMiddle)
        if verifiedRect != .zero { CellDrawing.draw(template: PixelGlyph.check.image(size: 9), in: verifiedRect, color: glyphColor) }
        if partialRect != .zero { CellDrawing.draw(template: PixelGlyph.partial.image(size: 9), in: partialRect, color: glyphColor) }
        if let status, statusRect != .zero { StatusDrawing(status: status, font: CellFonts.caption).draw(in: statusRect, emphasized: emphasized) }
    }

}

extension NameCellView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        if disclosureRect.contains(point) { return isExpanded ? "Hide contents" : "Show contents" }
        if verifiedRect.contains(point) { return verifiedHelp ?? "" }
        if partialRect.contains(point) { return partialHelp ?? "" }
        if statusRect.contains(point) { return status?.help ?? "" }
        if nameRect.contains(point), nameTruncated { return item?.name ?? "" }
        return ""
    }
}

/// Modified, Size and Kind: one line of secondary text.
final class TextCellView: DrawnCellView {
    private let font: NSFont
    private let alignment: NSTextAlignment
    private var text = ""

    init(identifier: NSUserInterfaceItemIdentifier, font: NSFont, alignment: NSTextAlignment) {
        self.font = font
        self.alignment = alignment
        super.init(identifier: identifier)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show(_ text: String, help: String? = nil) {
        if self.text != text {
            self.text = text
            setAccessibilityLabel(text)
            needsDisplay = true
        }
        if toolTip != help { toolTip = help }
    }

    override func draw(_ dirtyRect: NSRect) {
        CellDrawing.draw(text, in: bounds, font: font, color: emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor,
                         alignment: alignment)
    }
}

/// The Status column.
final class StatusCellView: DrawnCellView {
    private var status: FileStatus?

    func show(_ status: FileStatus?) {
        guard status != self.status else { return }
        self.status = status
        toolTip = status?.help
        setAccessibilityLabel(status.map { "Status: \($0.text)" } ?? "")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let status else { return }
        StatusDrawing(status: status, font: CellFonts.digits).draw(in: bounds, emphasized: emphasized)
    }
}
