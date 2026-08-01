// Generates Sill.icns — plain white ground, "Sill" set in it. No logo, no gradient.
// Run: swift tools/make-icon.swift /tmp/sill.iconset
//      iconutil -c icns /tmp/sill.iconset -o Resources/Sill.icns

import AppKit
import Foundation

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

/// macOS icons sit on a rounded-square ground with a small margin, or they look
/// oversized next to every other app in the Dock.
func render(_ px: Int) -> Data? {
    let size = CGFloat(px)

    // A raw bitmap context rather than NSImage.lockFocus — lockFocus is backed by the
    // current display and silently fails above ~1024pt on some machines.
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                     pixelsWide: px, pixelsHigh: px,
                                     bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0),
          let gc = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = gc
    defer { NSGraphicsContext.restoreGraphicsState() }

    let ctx = gc.cgContext
    ctx.setShouldAntialias(true)

    let inset = size * 0.0586                    // Apple's grid: 60/1024
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237             // squircle-ish corner

    let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSColor.white.setFill()
    path.fill()

    // A hairline so the tile still holds an edge against a white background.
    NSColor(srgbRed: 0.886, green: 0.878, blue: 0.859, alpha: 1).setStroke()
    path.lineWidth = max(1, size * 0.0025)
    path.stroke()

    let text = "Sill"
    let fontSize = size * 0.30
    let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(srgbRed: 0.129, green: 0.125, blue: 0.110, alpha: 1),
        .kern: -fontSize * 0.02
    ]
    let str = NSAttributedString(string: text, attributes: attrs)
    let bounds = str.size()
    str.draw(at: NSPoint(x: (size - bounds.width) / 2,
                         y: (size - bounds.height) / 2))

    gc.flushGraphics()
    return rep.representation(using: .png, properties: [:])
}

// The exact set `iconutil` expects.
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),      (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),      (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),   (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),   (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),   (1024, "icon_512x512@2x.png"),
]

for (px, name) in sizes {
    guard let data = render(px) else { print("failed \(name)"); continue }
    try data.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
}
print("wrote \(sizes.count) sizes to \(out)")
