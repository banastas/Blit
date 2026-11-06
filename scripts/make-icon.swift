// Renders Blit's app icon as an Icon Composer document (Blit/AppIcon.icon): pixel art on a 14×12 grid (a download
// arrow over a row of HUD progress cells) over a solid near-black fill, glass off. macOS 26+ applies the icon shape
// itself; artwork drawn with its own rounded rect and margins gets placed in a grey container instead. The glitch
// treatment is Repertory's (below).
//
//   swift scripts/make-icon.swift Blit/AppIcon.icon [preview.png]
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
let bundle = CommandLine.arguments[1]
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
if CommandLine.arguments.count > 2 {
    // The preview, as macOS draws the icon (Icon Composer's renderer).
    let ictool = "/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: ictool)
    p.arguments = [bundle, "--export-image", "--output-file", CommandLine.arguments[2], "--platform", "macOS",
                   "--rendition", "Default", "--width", "1024", "--height", "1024", "--scale", "1"]
    try! p.run()
    p.waitUntilExit()
    print(p.terminationStatus == 0 ? "wrote \(CommandLine.arguments[2])" : "ictool failed (\(p.terminationStatus))")
}
