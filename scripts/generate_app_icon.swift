#!/usr/bin/env swift
import AppKit

// Generates AppIcon.icns into Resources/. Design: rounded-square plate with a
// green→teal gradient (money/cost theme) and a bold "$" gauge glyph — this is
// the Finder/DMG icon, not the menu bar glyph (which stays an SF Symbol).

func glyphImage(pointSize: CGFloat) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    let candidates = ["dollarsign.gauge.chart.lefthalf.righthalf", "dollarsign.circle.fill", "dollarsign"]
    for name in candidates {
        if let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
           let img = base.withSymbolConfiguration(cfg) {
            return img
        }
    }
    fatalError("No glyph symbol available")
}

func renderIcon(size: Int) -> Data {
    let dim = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    rep.size = NSSize(width: dim, height: dim)

    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high

    let margin = dim * 0.085
    let plate = NSRect(x: margin, y: margin, width: dim - 2 * margin, height: dim - 2 * margin)
    let radius = plate.width * 0.2237
    let path = NSBezierPath(roundedRect: plate, xRadius: radius, yRadius: radius)

    // Diagonal green → teal gradient.
    let top = NSColor(srgbRed: 0.16, green: 0.66, blue: 0.42, alpha: 1.0)    // #29A86C
    let bottom = NSColor(srgbRed: 0.06, green: 0.45, blue: 0.55, alpha: 1.0) // #0F738C
    let gradient = NSGradient(colors: [top, bottom])!
    gradient.draw(in: path, angle: -65)

    // Subtle top highlight for depth.
    let highlight = NSGradient(colors: [
        NSColor(white: 1.0, alpha: 0.16), NSColor(white: 1.0, alpha: 0.0),
    ])!
    highlight.draw(in: path, angle: -90)

    // Centered white glyph.
    let glyph = glyphImage(pointSize: dim * 0.50)
    let gs = glyph.size
    let gx = (dim - gs.width) / 2
    let gy = (dim - gs.height) / 2
    glyph.draw(in: NSRect(x: gx, y: gy, width: gs.width, height: gs.height),
               from: .zero, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

// macOS iconset sizes (pt@scale -> px).
let entries: [(sizePt: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

let iconsetDir = "build/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconsetDir)
try! FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

for e in entries {
    let px = e.sizePt * e.scale
    let suffix = e.scale == 1 ? "" : "@2x"
    let file = "icon_\(e.sizePt)x\(e.sizePt)\(suffix).png"
    try! renderIcon(size: px).write(to: URL(fileURLWithPath: "\(iconsetDir)/\(file)"))
}

print("Wrote iconset to \(iconsetDir)")

// Convert to .icns via iconutil and drop into Resources/.
let outIcns = "Resources/AppIcon.icns"
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir, "-o", outIcns]
try! proc.run()
proc.waitUntilExit()
if proc.terminationStatus == 0 {
    print("Wrote \(outIcns)")
} else {
    print("iconutil failed with status \(proc.terminationStatus)")
    exit(1)
}
