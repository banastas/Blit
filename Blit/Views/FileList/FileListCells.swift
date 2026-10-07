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
    /// Quick Look thumbnails for local files (View › Show Icon Previews).
    let iconPreviews: Bool
}

/// The list's fonts: the system body font (what the SwiftUI Table used, until
/// 0.2.41), with even digits where numbers line up.
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

/// A row's mark against the other pane's folder (View › Compare Panes): a
/// word, with the pixel ✓ for a verified copy there and ◐ for one still being
/// downloaded. Orange only where the two differ, the accent colour where it's
/// only here.
@MainActor
struct CompareDrawing {
    let comparison: PaneComparison
    let font: NSFont

    private var glyph: PixelGlyph? {
        switch comparison.kind {
        case .verifiedThere: .check
        case .partlyThere: .partial
        default: nil
        }
    }

    var width: CGFloat { (glyph == nil ? 0 : 9 + 4) + CellDrawing.width(comparison.text, font: font) }

    func draw(in rect: NSRect, emphasized: Bool) {
        let color: NSColor = if emphasized { .alternateSelectedControlTextColor } else {
            switch comparison.kind {
            case .onlyHere: .controlAccentColor
            case .differs: .systemOrange
            case .same, .verifiedThere, .partlyThere: .secondaryLabelColor
            }
        }
        var x = rect.minX
        if let glyph {
            CellDrawing.draw(template: glyph.image(size: 9), in: NSRect(x: x, y: (rect.midY - 4.5).rounded(), width: 9, height: 9), color: color)
            x += 13
        }
        CellDrawing.draw(comparison.text, in: NSRect(x: x, y: rect.minY, width: rect.maxX - x, height: rect.height), font: font, color: color)
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

    /// A dragged row's image is its icon and name (NameCellView's), as in Finder.
    override var draggingImageComponents: [NSDraggingImageComponent] { [] }
}

/// The Name column: indent, disclosure triangle, icon, the name (shortened in
/// the middle, so a release's year, group and extension stay in view), then
/// the ✓ verified and ◐ partial glyphs, the compare tag and the status tag.
final class NameCellView: DrawnCellView {
    private(set) var item: FileItem?
    private var icon: NSImage?
    /// The thumbnail being made for this row, if any.
    private var thumbnailTask: Task<Void, Never>?
    private var isExpanded = false
    /// The folder's contents are loading: a pixel spinner in place of the triangle.
    private var isLoading = false
    private var spinner: Timer?
    /// The rename field, over the name while it's edited.
    private var editor: NSTextField?
    private var verifiedHelp: String?
    private var partialHelp: String?
    /// New since this folder was last left: an accent dot after the name.
    private var isNew = false
    private var newRect = NSRect.zero
    /// With Compare Panes on: how the row stands against the other pane's folder.
    private var comparison: PaneComparison?
    private var compareRect = NSRect.zero
    private var status: FileStatus?
    /// Where each part was drawn, for tooltips and the drag rule.
    private(set) var nameRect = NSRect.zero
    private(set) var iconRect = NSRect.zero
    private var disclosureRect = NSRect.zero
    #if DEBUG
    /// Where the disclosure triangle is (the tests click it).
    var disclosureFrame: NSRect { disclosureRect }
    #endif
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
        let loading = expanded && browser.loadingChildren.contains(item.location)
        let new = browser.isNew(item)
        let comparison = browser.comparison(for: item)
        let changed = item != self.item || verifiedHelp != self.verifiedHelp || partialHelp != self.partialHelp
            || status != self.status || expanded != isExpanded || loading != isLoading || new != isNew
            || comparison != self.comparison
        if item.id != self.item?.id || item.modified != self.item?.modified || icon == nil {
            showIcon(for: item, previews: context.iconPreviews)
        }
        setLoading(loading)
        self.item = item
        self.verifiedHelp = verifiedHelp
        self.partialHelp = partialHelp
        self.status = status
        isExpanded = expanded
        isNew = new
        self.comparison = comparison
        if changed {
            setAccessibilityLabel(([item.name] + [new ? "New" : nil, entry == nil ? nil : "Verified", item.partial == nil ? nil : "Partial download",
                                                  comparison?.help, status.map { "Status: \($0.text)" }].compactMap { $0 }).joined(separator: ", "))
            needsLayout = true
            needsDisplay = true
        }
    }

    /// The type icon, or (for a local file, with previews on) its Quick Look
    /// thumbnail: at once if it was made before, else when it's ready.
    private func showIcon(for item: FileItem, previews: Bool) {
        thumbnailTask?.cancel()
        thumbnailTask = nil
        icon = IconCache.shared.rowIcon(for: item)
        guard previews, !item.isDirectory, let url = item.location.localURL else { return }
        let cache = ThumbnailCache.shared
        if let thumbnail = cache.cached(for: url, modified: item.modified) {
            icon = thumbnail
            return
        }
        guard !cache.hasNone(for: url, modified: item.modified) else { return }
        let id = item.id
        thumbnailTask = Task { [weak self] in
            guard let thumbnail = await cache.thumbnail(for: url, modified: item.modified),
                  !Task.isCancelled, let self, self.item?.id == id else { return }
            self.icon = thumbnail
            self.needsDisplay = true
        }
    }

    private func setLoading(_ loading: Bool) {
        guard loading != isLoading else { return }
        isLoading = loading
        spinner?.invalidate()
        spinner = nil
        if loading {
            spinner = Timer.scheduledTimer(withTimeInterval: 0.09, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.setNeedsDisplay(self?.disclosureRect ?? .zero) }
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        setLoading(false)
    }

    /// Shows `field` over the name (from where the name starts to the cell's end).
    func beginEditing(with field: NSTextField) {
        editor?.removeFromSuperview()
        editor = field
        addSubview(field)
        needsLayout = true
        layoutSubtreeIfNeeded()
        needsDisplay = true
    }

    func endEditing() {
        editor = nil
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { setLoading(false) }
    }

    /// Where the drawn content ends: the name and the marks after it.
    var contentEnd: CGFloat { [nameRect, newRect, verifiedRect, partialRect, compareRect, statusRect].map(\.maxX).max() ?? 0 }

    /// The icon and the name, as the drag image.
    override var draggingImageComponents: [NSDraggingImageComponent] {
        guard let item, iconRect != .zero else { return [] }
        let rect = NSRect(x: iconRect.minX, y: 0, width: max(nameRect.maxX, iconRect.maxX) - iconRect.minX, height: bounds.height)
        let icon = self.icon, iconFrame = iconRect.offsetBy(dx: -rect.minX, dy: 0), nameFrame = nameRect.offsetBy(dx: -rect.minX, dy: 0)
        let image = NSImage(size: rect.size, flipped: true) { _ in
            icon?.draw(in: iconFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            CellDrawing.draw(item.name, in: nameFrame, font: CellFonts.body, color: .labelColor, lineBreak: .byTruncatingMiddle)
            return true
        }
        let component = NSDraggingImageComponent(key: .icon)
        component.contents = image
        component.frame = rect
        return [component]
    }

    /// Whether `point` (this cell's coordinates) is on a folder's disclosure
    /// triangle, give or take a little. The table takes every click in its rows
    /// (NSTableView hit-tests them itself), so it asks.
    func isOnDisclosure(_ point: NSPoint) -> Bool {
        item?.isDirectory == true && disclosureRect.insetBy(dx: -2, dy: -4).contains(point)
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
        let compareWidth: CGFloat = comparison.map { CompareDrawing(comparison: $0, font: CellFonts.caption).width } ?? 0
        var trailing: CGFloat = 0
        if isNew { trailing += 5 + 7 }
        if verifiedHelp != nil { trailing += 5 + 9 }
        if partialHelp != nil { trailing += 5 + 9 }
        if comparison != nil { trailing += 6 + compareWidth }
        if status != nil { trailing += 5 + statusWidth }
        let natural = CellDrawing.width(item.name, font: CellFonts.body)
        let nameWidth = max(0, min(natural, bounds.width - x - trailing))
        nameTruncated = nameWidth < natural
        nameRect = NSRect(x: x, y: 0, width: nameWidth, height: height)
        x += nameWidth
        newRect = .zero
        verifiedRect = .zero
        partialRect = .zero
        compareRect = .zero
        statusRect = .zero
        if isNew {
            newRect = NSRect(x: x + 5, y: centered(7), width: 7, height: 7)
            x += 5 + 7
        }
        if verifiedHelp != nil {
            verifiedRect = NSRect(x: x + 5, y: centered(9), width: 9, height: 9)
            x += 5 + 9
        }
        if partialHelp != nil {
            partialRect = NSRect(x: x + 5, y: centered(9), width: 9, height: 9)
            x += 5 + 9
        }
        if comparison != nil {
            compareRect = NSRect(x: x + 6, y: 0, width: compareWidth, height: height)
            x += 6 + compareWidth
        }
        if status != nil {
            statusRect = NSRect(x: x + 5, y: 0, width: statusWidth, height: height)
        }
        if let editor {
            let height = ceil(editor.intrinsicContentSize.height)
            editor.frame = NSRect(x: nameRect.minX - 4, y: centered(height), width: bounds.width - nameRect.minX + 4, height: height)
        }
        removeAllToolTips()
        if disclosureRect != .zero { addToolTip(disclosureRect, owner: self, userData: nil) }
        if nameTruncated { addToolTip(nameRect, owner: self, userData: nil) }
        for rect in [newRect, verifiedRect, partialRect, compareRect, statusRect] where rect != .zero { addToolTip(rect, owner: self, userData: nil) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let item else { return }
        let glyphColor: NSColor = emphasized ? .alternateSelectedControlTextColor : .secondaryLabelColor
        if disclosureRect != .zero, isLoading {
            drawSpinner(in: disclosureRect, color: emphasized ? .alternateSelectedControlTextColor : .labelColor)
        } else if disclosureRect != .zero, let chevron = isExpanded ? Self.chevronDown : Self.chevron {
            let size = chevron.size
            let rect = NSRect(x: disclosureRect.midX - size.width / 2, y: disclosureRect.midY - size.height / 2,
                              width: size.width, height: size.height).integral
            CellDrawing.draw(template: chevron, in: rect, color: glyphColor)
        }
        if let icon {
            // Thumbnails keep their shape inside the icon's square.
            let size = icon.size
            let scale = min(iconRect.width / max(size.width, 1), iconRect.height / max(size.height, 1), 1)
            let fitted = NSRect(x: iconRect.midX - size.width * scale / 2, y: iconRect.midY - size.height * scale / 2,
                                width: size.width * scale, height: size.height * scale)
            icon.draw(in: size.width <= iconRect.width && size.height <= iconRect.height ? iconRect : fitted,
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        // While the name is edited, the field shows it (and the marks after it wait).
        guard editor == nil else { return }
        CellDrawing.draw(item.name, in: nameRect, font: CellFonts.body,
                         color: emphasized ? .alternateSelectedControlTextColor : .labelColor, lineBreak: .byTruncatingMiddle)
        if newRect != .zero {
            (emphasized ? NSColor.alternateSelectedControlTextColor : NSColor.controlAccentColor).setFill()
            NSBezierPath(ovalIn: newRect).fill()
        }
        if verifiedRect != .zero { CellDrawing.draw(template: PixelGlyph.check.image(size: 9), in: verifiedRect, color: glyphColor) }
        if partialRect != .zero { CellDrawing.draw(template: PixelGlyph.partial.image(size: 9), in: partialRect, color: glyphColor) }
        if let comparison, compareRect != .zero { CompareDrawing(comparison: comparison, font: CellFonts.caption).draw(in: compareRect, emphasized: emphasized) }
        if let status, statusRect != .zero { StatusDrawing(status: status, font: CellFonts.caption).draw(in: statusRect, emphasized: emphasized) }
    }

}

#if DEBUG
extension NameCellView {
    /// What the cell shows, for the tests.
    var testSummary: String {
        guard let item else { return "-" }
        var parts = [String(repeating: "  ", count: item.depth) + item.name]
        if item.isDirectory { parts.append(isLoading ? "loading" : isExpanded ? "open" : "closed") }
        if verifiedHelp != nil { parts.append("✓") }
        if partialHelp != nil { parts.append("◐") }
        if let comparison { parts.append("{\(comparison.text)}") }
        if let status { parts.append("[\(status.glyph.map(String.init) ?? "")\(status.text)]") }
        return parts.joined(separator: " ")
    }
}
#endif

extension NameCellView {
    /// PixelSpinner's ring of eight 1.5-pt pixels, its head going round.
    private static let ring = [(0, 0), (1, 0), (2, 0), (2, 1), (2, 2), (1, 2), (0, 2), (0, 1)]

    fileprivate func drawSpinner(in rect: NSRect, color: NSColor) {
        let cell: CGFloat = 1.5
        let side = cell * 5
        let origin = NSPoint(x: (rect.midX - side / 2).rounded(), y: (rect.midY - side / 2).rounded())
        let head = Int(Date.timeIntervalSinceReferenceDate / 0.09) % Self.ring.count
        for (index, (x, y)) in Self.ring.enumerated() {
            let age = (head - index + Self.ring.count) % Self.ring.count
            let opacity: CGFloat = age == 0 ? 1 : age == 1 ? 0.6 : age == 2 ? 0.3 : 0.12
            color.withAlphaComponent(opacity).setFill()
            NSRect(x: origin.x + CGFloat(x) * cell * 2, y: origin.y + CGFloat(y) * cell * 2, width: cell, height: cell).fill()
        }
    }
}

extension NameCellView: NSViewToolTipOwner {
    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        if disclosureRect.contains(point) { return isExpanded ? "Hide contents" : "Show contents" }
        if newRect.contains(point) { return "New since you last left this folder" }
        if verifiedRect.contains(point) { return verifiedHelp ?? "" }
        if partialRect.contains(point) { return partialHelp ?? "" }
        if compareRect.contains(point) { return comparison?.help ?? "" }
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
