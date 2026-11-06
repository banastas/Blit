// Renders Blit's app icon as an Icon Composer document (Blit/AppIcon.icon): pixel art on a 14×12 grid (a download
// arrow over a row of HUD progress cells) over a solid near-black fill, glass off. macOS 26+ applies the icon shape
// itself; artwork drawn with its own rounded rect and margins gets placed in a grey container instead. The glitch
// treatment is Repertory's (below).
//
//   swift scripts/make-icon.swift Blit/AppIcon.icon [preview.png] [--site site]
import AppKit

let name = "blit"
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
    "##.##.##.##.::",   // progress cells: the last one lit
]
/// The glyph: the rows above the progress cells.
let glyphRows = 0..<9
let glyphShift = 0.0
/// The glitch slice, in rows from the top of the grid: a band through the arrowhead.
let slice = 5.3..<5.8

// The family's look since 2026-11-05, from Repertory's tools/make_icon.py: a near-black ink fill; the mark in
// off-white with a cyan ghost split to its left and a magenta one to its right; one horizontal slice of the glyph
// knocked sideways; the family mark's last cell lit cyan with a glow; faint scanlines and soft cyan and magenta
// washes from opposite corners. Three layers, glass off: the ground (washes, scanlines), the glitch (shadow,
// ghosts, glow) and the mark. In the tinted and clear appearances the ground and glitch layers are hidden, so the
// system's monochrome icon is the mark alone.
let ink = (8.0, 8.0, 10.0)                                  // the fill; the ground layer lifts its top towards 22
let paperTop = (251.0, 250.0, 246.0), paperBottom = (228.0, 226.0, 220.0)
let cyan = (0.0, 237.0, 255.0), magenta = (255.0, 43.0, 204.0)
var args = Array(CommandLine.arguments.dropFirst())
/// `--site <dir>` also writes the website's icon.svg (the whole icon) and favicon.svg (the art filling a 16-cell tile).
var site: String?
if let i = args.firstIndex(of: "--site"), i + 1 < args.count { site = args[i + 1]; args.removeSubrange(i...i + 1) }
let bundle = args[0]
let preview = args.count > 1 ? args[1] : nil
let canvas = 1024
let cols = art[0].count, rows = art.count
let cell = Double(Int(Double(canvas) * 0.56) / cols)       // whole pixels per cell (40: half a cell is whole too)
let x0 = Double((canvas - Int(cell) * cols) / 2)
let y0 = Double((canvas - Int(cell) * rows) / 2)
let sliceShift = (cell * 0.6).rounded()                     // the slice moves right by this much
let split = (cell * 0.4).rounded()                          // each ghost's offset

func rgb(_ c: (Double, Double, Double), _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: a)
}

/// Cells of the art in CG coordinates (y up), the slice knocked sideways; `glyphOnly` leaves out the family mark.
func cells(glyphOnly: Bool, lit: Bool = false) -> [CGRect] {
    let bandTop = Double(canvas) - (y0 + slice.lowerBound * cell)          // top of the slice band, y up
    let bandBottom = Double(canvas) - (y0 + slice.upperBound * cell)
    var out: [CGRect] = []
    for (r, line) in art.enumerated() where !(glyphOnly && !glyphRows.contains(r)) {
        let shift = glyphRows.contains(r) ? glyphShift * cell : 0
        for (c, ch) in line.enumerated() where ch != "." && (ch == ":") == lit {
            let rect = CGRect(x: x0 + Double(c) * cell + shift, y: Double(canvas) - y0 - Double(r + 1) * cell,
                              width: cell, height: cell)
            guard glyphRows.contains(r), rect.maxY > bandBottom, rect.minY < bandTop else { out.append(rect); continue }
            let inBand = rect.intersection(CGRect(x: 0, y: bandBottom, width: Double(canvas), height: bandTop - bandBottom))
            if rect.maxY > bandTop { out.append(CGRect(x: rect.minX, y: bandTop, width: cell, height: rect.maxY - bandTop)) }
            if rect.minY < bandBottom { out.append(CGRect(x: rect.minX, y: rect.minY, width: cell, height: bandBottom - rect.minY)) }
            out.append(inBand.offsetBy(dx: sliceShift, dy: 0))
        }
    }
    return out
}

func draw(_ body: (CGContext) -> Void) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    body(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!

/// A soft glow of `colour` from a corner (`cx`, `cy` in 0-1, y up), fading as (1 - r)².
func wash(_ ctx: CGContext, _ colour: (Double, Double, Double), cx: Double, cy: Double, radius: Double, strength: Double) {
    let steps = 12
    let colours = (0...steps).map { i -> CGColor in let r = Double(i) / Double(steps); return rgb(colour, strength * (1 - r) * (1 - r)) }
    let gradient = CGGradient(colorsSpace: space, colors: colours as CFArray,
                              locations: (0...steps).map { CGFloat($0) / CGFloat(steps) })!
    let centre = CGPoint(x: cx * Double(canvas), y: cy * Double(canvas))
    ctx.drawRadialGradient(gradient, startCenter: centre, startRadius: 0, endCenter: centre,
                           endRadius: radius * Double(canvas), options: [])
}

/// The ground: the top lifted a little, the washes, the scanlines. Transparent over the solid fill.
func ground() -> Data {
    draw { ctx in
        let lift = CGGradient(colorsSpace: space, colors: [CGColor(gray: 1, alpha: 0.057), CGColor(gray: 1, alpha: 0)] as CFArray,
                              locations: [0, 1])!
        ctx.drawLinearGradient(lift, start: CGPoint(x: 0, y: canvas), end: CGPoint(x: 0, y: 0), options: [])
        wash(ctx, cyan, cx: 1, cy: 1, radius: 1.1, strength: 0.17)
        wash(ctx, magenta, cx: 0, cy: 0, radius: 1.0, strength: 0.16)
        let step = canvas / 110
        ctx.setFillColor(CGColor(gray: 1, alpha: 9.0 / 255))
        for y in stride(from: 0, to: canvas, by: step) { ctx.fill(CGRect(x: 0, y: y, width: canvas, height: max(1, step / 3))) }
    }
}

/// The glitch: the glyph's shadow, its cyan and magenta ghosts, and the lit cell's glow.
func glitch() -> Data {
    draw { ctx in
        let glyph = cells(glyphOnly: true)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -cell * 0.45), blur: cell * 0.9, color: CGColor(gray: 0, alpha: 0.55))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(glyph)
        ctx.restoreGState()
        for (colour, dx) in [(cyan, -split), (magenta, split)] {
            ctx.setFillColor(rgb(colour, 0.85))
            ctx.fill(glyph.map { $0.offsetBy(dx: dx, dy: 0) })
        }
        ctx.setShadow(offset: .zero, blur: cell * 1.1, color: rgb(cyan, 1))
        ctx.setFillColor(rgb(cyan))
        for _ in 0..<2 { ctx.fill(cells(glyphOnly: false, lit: true)) }
    }
}

/// The mark: the glyph and the family mark in off-white, the last cell lit cyan.
func mark() -> Data {
    draw { ctx in
        ctx.setShouldAntialias(false)
        ctx.saveGState()
        ctx.clip(to: cells(glyphOnly: false))
        let paper = CGGradient(colorsSpace: space, colors: [rgb(paperTop), rgb(paperBottom)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(paper, start: CGPoint(x: 0, y: Double(canvas) - y0), end: CGPoint(x: 0, y: y0), options: [])
        ctx.restoreGState()
        ctx.setFillColor(rgb(cyan))
        ctx.fill(cells(glyphOnly: false, lit: true))
    }
}

let fm = FileManager.default
try? fm.removeItem(atPath: bundle)
try! fm.createDirectory(atPath: bundle + "/Assets", withIntermediateDirectories: true)
let layers = [(name, mark()), ("glitch", glitch()), ("ground", ground())]
for (layer, png) in layers { try! png.write(to: URL(fileURLWithPath: bundle + "/Assets/\(layer).png")) }
func layerJSON(_ layer: String, monochrome: Bool) -> String {
    let hidden = monochrome ? "" : """

              "hidden-specializations" : [
                { "appearance" : "tinted", "value" : true }
              ],
    """
    return """
            {
              "glass" : false,\(hidden)
              "image-name" : "\(layer).png",
              "name" : "\(layer)"
            }
    """
}
let f = { (v: Double) in String(format: "%.5f", v / 255) }
let json = """
{
  "fill" : {
    "solid" : "extended-srgb:\(f(ink.0)),\(f(ink.1)),\(f(ink.2)),1.00000"
  },
  "groups" : [
    {
      "layers" : [
\(layers.map { layerJSON($0.0, monochrome: $0.0 == name) }.joined(separator: ",\n"))
      ],
      "shadow" : {
        "kind" : "none",
        "opacity" : 0
      }
    }
  ],
  "supported-platforms" : {
    "squares" : [
      "macOS"
    ]
  }
}

"""
try! json.write(toFile: bundle + "/icon.json", atomically: true, encoding: .utf8)
print("wrote \(bundle)")
if let preview {
    // The preview, as macOS draws the icon (Icon Composer's renderer).
    let ictool = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ictool)
    p.arguments = [bundle, "--export-image", "--output-file", preview, "--platform", "macOS",
                   "--rendition", "Default", "--width", "1024", "--height", "1024", "--scale", "1"]
    p.standardOutput = FileHandle.nullDevice
    try! p.run()
    p.waitUntilExit()
    print(p.terminationStatus == 0 ? "wrote \(preview)" : "ictool failed (\(p.terminationStatus))")
}

/// The same icon as SVG for the website, in the canvas's pixels (y down), cropped to `box` with corners of `corner`.
func svg(box: CGRect, corner: Double, scanlines: Bool) -> String {
    func hex(_ c: (Double, Double, Double)) -> String { String(format: "#%02x%02x%02x", Int(c.0), Int(c.1), Int(c.2)) }
    func n(_ v: Double) -> String { String(format: "%g", (v * 100).rounded() / 100) }
    func rect(_ r: CGRect, _ attrs: String = "") -> String {
        "<rect x=\"\(n(r.minX))\" y=\"\(n(Double(canvas) - r.maxY))\" width=\"\(n(r.width))\" height=\"\(n(r.height))\"\(attrs)/>"
    }
    let s = box.width, (bx, by) = (box.minX, box.minY)
    let glyph = cells(glyphOnly: true), all = cells(glyphOnly: false), lit = cells(glyphOnly: false, lit: true)
    var o = "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"\(n(bx)) \(n(by)) \(n(s)) \(n(s))\">\n<defs>\n"
    o += "<clipPath id=\"tile\"><rect x=\"\(n(bx))\" y=\"\(n(by))\" width=\"\(n(s))\" height=\"\(n(s))\" rx=\"\(n(corner))\"/></clipPath>\n"
    o += "<linearGradient id=\"lift\" x1=\"0\" y1=\"0\" x2=\"0\" y2=\"1\"><stop offset=\"0\" stop-color=\"#fff\" stop-opacity=\"0.057\"/><stop offset=\"1\" stop-color=\"#fff\" stop-opacity=\"0\"/></linearGradient>\n"
    for (id, c, cx, cy, r, k) in [("cyan", cyan, bx + s, by, 1.1, 0.17), ("magenta", magenta, bx, by + s, 1.0, 0.16)] {
        let stops = (0...6).map { i -> String in let t = Double(i) / 6; return "<stop offset=\"\(n(t))\" stop-color=\"\(hex(c))\" stop-opacity=\"\(String(format: "%.4f", k * (1 - t) * (1 - t)))\"/>" }
        o += "<radialGradient id=\"\(id)\" gradientUnits=\"userSpaceOnUse\" cx=\"\(n(cx))\" cy=\"\(n(cy))\" r=\"\(n(r * s))\">\(stops.joined())</radialGradient>\n"
    }
    let step = Double(canvas / 110) * s / Double(canvas)
    o += "<pattern id=\"scan\" patternUnits=\"userSpaceOnUse\" width=\"\(n(s))\" height=\"\(n(step))\"><rect width=\"\(n(s))\" height=\"\(n(step / 3))\" fill=\"#fff\" fill-opacity=\"0.035\"/></pattern>\n"
    o += "<linearGradient id=\"paper\" gradientUnits=\"userSpaceOnUse\" x1=\"0\" y1=\"\(n(y0))\" x2=\"0\" y2=\"\(n(Double(canvas) - y0))\"><stop offset=\"0\" stop-color=\"\(hex(paperTop))\"/><stop offset=\"1\" stop-color=\"\(hex(paperBottom))\"/></linearGradient>\n"
    o += "<filter id=\"shadow\" x=\"-20%\" y=\"-20%\" width=\"140%\" height=\"140%\"><feGaussianBlur stdDeviation=\"\(n(cell * 0.45))\"/></filter>\n"
    o += "<filter id=\"glow\" x=\"-100%\" y=\"-100%\" width=\"300%\" height=\"300%\"><feGaussianBlur stdDeviation=\"\(n(cell * 0.55))\"/></filter>\n"
    o += "</defs>\n<g clip-path=\"url(#tile)\">\n"
    let tile = "x=\"\(n(bx))\" y=\"\(n(by))\" width=\"\(n(s))\" height=\"\(n(s))\""
    o += "<rect \(tile) fill=\"\(hex(ink))\"/><rect \(tile) fill=\"url(#lift)\"/><rect \(tile) fill=\"url(#cyan)\"/><rect \(tile) fill=\"url(#magenta)\"/>\n"
    if scanlines { o += "<rect \(tile) fill=\"url(#scan)\"/>\n" }
    o += "<g filter=\"url(#shadow)\" fill=\"#000\" fill-opacity=\"0.55\" transform=\"translate(0 \(n(cell * 0.45)))\">\(glyph.map { rect($0) }.joined())</g>\n"
    o += "<g shape-rendering=\"crispEdges\">\n"
    for (c, dx) in [(cyan, -split), (magenta, split)] {
        o += "<g fill=\"\(hex(c))\" fill-opacity=\"0.85\">\(glyph.map { rect($0.offsetBy(dx: dx, dy: 0)) }.joined())</g>\n"
    }
    o += "</g>\n<g filter=\"url(#glow)\" fill=\"\(hex(cyan))\">\(lit.map { rect($0) }.joined())</g>\n"
    o += "<g shape-rendering=\"crispEdges\"><g fill=\"url(#paper)\">\(all.map { rect($0) }.joined())</g><g fill=\"\(hex(cyan))\">\(lit.map { rect($0) }.joined())</g></g>\n"
    return o + "</g>\n</svg>\n"
}
if let site {
    // icon.svg: the whole canvas, in the shape macOS gives it. favicon.svg: a 16-cell tile around the 14×12 grid.
    try! svg(box: CGRect(x: 0, y: 0, width: canvas, height: canvas), corner: Double(canvas) * 0.225, scanlines: true)
        .write(toFile: site + "/icon.svg", atomically: true, encoding: .utf8)
    let fav = CGRect(x: x0 - cell, y: y0 - 2 * cell, width: 16 * cell, height: 16 * cell)
    try! svg(box: fav, corner: 3.5 * cell, scanlines: false).write(toFile: site + "/favicon.svg", atomically: true, encoding: .utf8)
    print("wrote \(site)/icon.svg, \(site)/favicon.svg")
}
