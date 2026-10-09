// Renders a page at a fixed size to a PNG with WebKit, offscreen: for scripts/make-brand.sh.
// Rune's renderer (Headless Brave hung at its first screenshot, 2026-10-08; WebKit is on every
// Mac), plus two things: a Retina Mac draws the page at 2×, and this averages each 2×2 block
// into one pixel (a resampler such as sips rings: dark halos around bright edges); and a page
// that marks its body data-ready="no" until its script ends fails the render if it never ends.
//
//   swift scripts/brand/render.swift <file.html#fragment> <width> <height> <out.png>
import AppKit
import WebKit

let args = CommandLine.arguments
guard args.count == 5, let width = Int(args[2]), let height = Int(args[3]) else {
    FileHandle.standardError.write(Data("usage: render.swift <file.html#fragment> <width> <height> <out.png>\n".utf8))
    exit(2)
}
let parts = args[1].split(separator: "#", maxSplits: 1).map(String.init)
let file = URL(fileURLWithPath: parts[0]).standardizedFileURL
var components = URLComponents(url: file, resolvingAgainstBaseURL: false)!
components.fragment = parts.count > 1 ? parts[1] : nil
let output = URL(fileURLWithPath: args[4])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

/// `image` at exactly width × height: each k×k block averaged when it's k times the size.
func exactSize(_ image: CGImage, width: Int, height: Int) -> CGImage? {
    let k = image.width / width
    let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let source = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                 bytesPerRow: image.width * 4, space: sRGB, bitmapInfo: info),
          let target = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                 bytesPerRow: width * 4, space: sRGB, bitmapInfo: info) else { return nil }
    source.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard k >= 1, image.width == width * k, image.height == height * k else {
        // Not a whole multiple: let Core Graphics scale it.
        target.interpolationQuality = .high
        target.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return target.makeImage()
    }
    let src = source.data!.assumingMemoryBound(to: UInt8.self), dst = target.data!.assumingMemoryBound(to: UInt8.self)
    for y in 0..<height {
        for x in 0..<width {
            for c in 0..<4 {
                var sum = 0
                for dy in 0..<k { for dx in 0..<k { sum += Int(src[((y * k + dy) * image.width + x * k + dx) * 4 + c]) } }
                dst[(y * width + x) * 4 + c] = UInt8((sum + k * k / 2) / (k * k))
            }
        }
    }
    return target.makeImage()
}

@MainActor
final class Renderer: NSObject, WKNavigationDelegate {
    let view: WKWebView
    init(width: Int, height: Int) {
        view = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        super.init()
        view.navigationDelegate = self
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Fonts and the page's script: a moment after the load.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            webView.evaluateJavaScript("document.body.dataset.ready") { ready, _ in
                if ready as? String == "no" { fail("the page's script didn't finish: open it in Safari and check its console") }
                let config = WKSnapshotConfiguration()
                config.rect = webView.bounds
                config.snapshotWidth = NSNumber(value: Int(webView.bounds.width))   // 1 pixel a point
                webView.takeSnapshot(with: config) { image, error in
                    guard let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                          let cg = rep.cgImage, let exact = exactSize(cg, width: Int(webView.bounds.width), height: Int(webView.bounds.height)),
                          let png = NSBitmapImageRep(cgImage: exact).representation(using: .png, properties: [:]) else {
                        fail("snapshot failed: \(String(describing: error))")
                    }
                    do { try png.write(to: output) } catch { fail("\(error)") }
                    exit(0)
                }
            }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        fail("load failed: \(error)")
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = MainActor.assumeIsolated { Renderer(width: width, height: height) }
MainActor.assumeIsolated {
    // The page reads its fonts from site/fonts: the repository's root readable.
    _ = renderer.view.loadFileURL(components.url!, allowingReadAccessTo: file.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
}
DispatchQueue.main.asyncAfter(deadline: .now() + 30) { fail("timed out") }
app.run()
