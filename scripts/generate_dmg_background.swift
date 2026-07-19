#!/usr/bin/env swift
import AppKit

// Generates the DMG installer window background (1200x800 px = 600x400 pt @2x).
// create-dmg places the app icon at window point (150,200) and the Applications
// folder at (450,200); this art sits behind them with a title and an arrow.

let W = 1200, H = 800
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: W, pixelsHigh: H,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = NSSize(width: W, height: H)
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = ctx
ctx.imageInterpolation = .high

let full = NSRect(x: 0, y: 0, width: W, height: H)

// Soft vertical gradient background (light mint-green → white; matches the
// "$ gauge" motif of the app icon).
let bg = NSGradient(colors: [
    NSColor(srgbRed: 0.93, green: 0.98, blue: 0.95, alpha: 1.0),
    NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0),
])!
bg.draw(in: full, angle: -90)

// Title (coordinates are bottom-origin; high y = near the top).
func drawCenteredText(_ text: String, y: CGFloat, size: CGFloat, color: NSColor, weight: NSFont.Weight) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
        .paragraphStyle: style,
    ]
    let s = NSAttributedString(string: text, attributes: attrs)
    let rect = NSRect(x: 0, y: y, width: CGFloat(W), height: size * 1.4)
    s.draw(in: rect)
}

drawCenteredText("LLM Cost Bar", y: 690, size: 52,
                 color: NSColor(srgbRed: 0.06, green: 0.38, blue: 0.27, alpha: 1.0), weight: .bold)
drawCenteredText("Drag the app onto the Applications folder to install",
                 y: 110, size: 28, color: NSColor(white: 0.45, alpha: 1.0), weight: .regular)

// Arrow at vertical center (y=400) pointing right, between the two icons.
let accent = NSColor(srgbRed: 0.13, green: 0.55, blue: 0.38, alpha: 1.0)
accent.setStroke()
accent.setFill()
let shaft = NSBezierPath()
shaft.lineWidth = 14
shaft.lineCapStyle = .round
shaft.move(to: NSPoint(x: 480, y: 400))
shaft.line(to: NSPoint(x: 700, y: 400))
shaft.stroke()
let head = NSBezierPath()
head.move(to: NSPoint(x: 740, y: 400))
head.line(to: NSPoint(x: 690, y: 372))
head.line(to: NSPoint(x: 690, y: 428))
head.close()
head.fill()

NSGraphicsContext.restoreGraphicsState()

let outDir = "build"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let data = rep.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: "\(outDir)/dmg_background.png"))
print("Wrote \(outDir)/dmg_background.png (\(W)x\(H))")
