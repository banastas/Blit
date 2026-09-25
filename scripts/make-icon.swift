// Blit app icon: 1-bit pixel art — a download arrow over a row of HUD progress
// cells, white on a near-black macOS rounded square.
import AppKit

let art = [
    "......##......",
    "......##......",
    "......##......",
    "......##......",
    "..##########..",
    "...########...",
    "....######....",
    ".....####.....",
    "......##......",
    "..............",
    "..............",
    "##.##.##.##.::",   // progress cells: last one dim
]
let out = CommandLine.arguments[1]

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.interpolationQuality = .none
    ctx.setShouldAntialias(px >= 64)
    let size = CGFloat(px)
    // macOS icon grid: the shape fills ~80% of the canvas, centred.
    let inset = (size * 0.1).rounded()
    let body = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let radius = body.width * 0.225
    ctx.addPath(CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.setFillColor(CGColor(gray: 0.045, alpha: 1))
    ctx.fillPath()
    ctx.setShouldAntialias(false)
    // Pixel art: whole device pixels per cell so every edge is crisp.
    let cols = art[0].count, rows = art.count
    let cell = max(1, Int((body.width * 0.62) / CGFloat(cols)))
    let artW = cell * cols, artH = cell * rows
    let x0 = Int(body.midX) - artW / 2
    let y0 = Int(body.midY) - artH / 2
    for (r, line) in art.enumerated() {
        for (c, ch) in line.enumerated() where ch != "." {
            ctx.setFillColor(CGColor(gray: ch == ":" ? 0.28 : 0.94, alpha: 1))
            // Core Graphics' origin is bottom-left; row 0 is the top of the art.
            ctx.fill(CGRect(x: x0 + c * cell, y: y0 + (rows - 1 - r) * cell, width: cell, height: cell))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (point, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
    for scale in scales {
        let px = point * scale
        let name = "icon_\(point)x\(point)\(scale == 2 ? "@2x" : "").png"
        try! render(px).write(to: URL(fileURLWithPath: "\(out)/\(name)"))
        images.append(["idiom": "mac", "size": "\(point)x\(point)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(out)/Contents.json"))
print("wrote \(images.count) icon images")
