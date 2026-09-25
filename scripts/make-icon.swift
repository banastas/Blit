// Renders Blit's app icon as an Icon Composer document (Blit/AppIcon.icon):
// a solid near-black fill plus one full-bleed pixel-art layer (a download
// arrow over a row of HUD progress cells). macOS 26+ applies the icon shape
// itself; artwork drawn with its own rounded rect and margins gets placed in
// a grey container instead.
//
//   swift scripts/make-icon.swift Blit/AppIcon.icon
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
let bundle = CommandLine.arguments[1]
let canvas = 1024

func renderArt() -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.setShouldAntialias(false)
    ctx.clear(CGRect(x: 0, y: 0, width: canvas, height: canvas))
    let cols = art[0].count, rows = art.count
    let cell = Int(Double(canvas) * 0.56) / cols           // whole pixels per cell
    let x0 = (canvas - cell * cols) / 2
    let y0 = (canvas - cell * rows) / 2
    for (r, line) in art.enumerated() {
        for (c, ch) in line.enumerated() where ch != "." {
            ctx.setFillColor(CGColor(gray: ch == ":" ? 0.3 : 0.95, alpha: 1))
            ctx.fill(CGRect(x: x0 + c * cell, y: y0 + (rows - 1 - r) * cell, width: cell, height: cell))
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
try? fm.removeItem(atPath: bundle)
try! fm.createDirectory(atPath: bundle + "/Assets", withIntermediateDirectories: true)
try! renderArt().write(to: URL(fileURLWithPath: bundle + "/Assets/blit.png"))
let json = """
{
  "fill" : {
    "solid" : "extended-srgb:0.04500,0.04500,0.04500,1.00000"
  },
  "groups" : [
    {
      "layers" : [
        {
          "glass" : false,
          "image-name" : "blit.png",
          "name" : "blit"
        }
      ]
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
