// Draws the app icon (Ferret's paw on its brown rounded square, on the macOS icon grid) at 1024 px:
// swift scripts/make-icon.swift <out.png>. The paw is the same shapes as Ferret's favicon (a 64-unit square).
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "icon-1024.png"
let size = 1024.0, box = 824.0, inset = (size - box) / 2
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// Soft shadow under the square, as macOS icons have.
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
let square = NSBezierPath(roundedRect: NSRect(x: inset, y: inset + 10, width: box, height: box), xRadius: box * 0.225, yRadius: box * 0.225)
NSColor(srgbRed: 0x7c / 255, green: 0x4a / 255, blue: 0x2d / 255, alpha: 1).setFill()
square.fill()
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// The favicon's paw, flipped to AppKit's bottom-up coordinates and scaled into the square.
let unit = box / 64
func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ degrees: Double) {
    ctx.saveGState()
    ctx.translateBy(x: inset + cx * unit, y: inset + 10 + (64 - cy) * unit)
    ctx.rotate(by: -degrees * .pi / 180)
    NSBezierPath(ovalIn: NSRect(x: -rx * unit, y: -ry * unit, width: rx * 2 * unit, height: ry * 2 * unit)).fill()
    ctx.restoreGState()
}
NSColor(srgbRed: 0xfd / 255, green: 0xf9 / 255, blue: 0xf4 / 255, alpha: 1).setFill()
ellipse(32, 42.5, 12.5, 10, 0)
ellipse(16.5, 29.5, 4.6, 6.2, -22)
ellipse(26, 19.5, 5, 6.6, -8)
ellipse(38, 19.5, 5, 6.6, 8)
ellipse(47.5, 29.5, 4.6, 6.2, 22)

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
