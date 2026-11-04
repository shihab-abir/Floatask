// Draws the Taskflow app icon (1024×1024 PNG). Used by scripts/make-icon.sh.
//   swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// macOS icon grid: 824pt tile centred in the 1024 canvas, continuous-corner radius ≈ 185.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.28))
ctx.addPath(tilePath)
ctx.setFillColor(color(0x5E8463))
ctx.fillPath()
ctx.restoreGState()

// Soft vertical gradient (sage).
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [color(0x7FA585), color(0x4F7354)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
ctx.restoreGState()

// Paper card.
let card = CGRect(x: 262, y: 262, width: 500, height: 500)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x1E2B20, 0.25))
ctx.addPath(CGPath(roundedRect: card, cornerWidth: 96, cornerHeight: 96, transform: nil))
ctx.setFillColor(color(0xFBFAF8))
ctx.fillPath()
ctx.restoreGState()

// Checkmark.
ctx.setStrokeColor(color(0x5E8463))
ctx.setLineWidth(62)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.move(to: CGPoint(x: 372, y: 520))
ctx.addLine(to: CGPoint(x: 470, y: 418))
ctx.addLine(to: CGPoint(x: 660, y: 618))
ctx.strokePath()

// Small amber "focus" dot.
ctx.setFillColor(color(0xE3A75E))
ctx.fillEllipse(in: CGRect(x: 690, y: 690, width: 92, height: 92))

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
