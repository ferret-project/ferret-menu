import AppKit

/// Ferret's paw (the favicon's shapes) as a menu bar template image: macOS tints it for light, dark and highlighted.
enum Paw {
    static let image: NSImage = {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            // The favicon draws in a 64-unit square; its paw sits in about 11…53 × 13…52.5, centred here.
            let scale = rect.width / 42
            let dx = -11.0 * scale, dy = -11.75 * scale
            NSColor.black.setFill()
            func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ degrees: Double) {
                let transform = NSAffineTransform()
                transform.translateX(by: cx * scale + dx, yBy: cy * scale + dy)
                transform.rotate(byDegrees: degrees)
                let path = NSBezierPath(ovalIn: NSRect(x: -rx * scale, y: -ry * scale, width: rx * 2 * scale, height: ry * 2 * scale))
                path.transform(using: transform as AffineTransform)
                path.fill()
            }
            ellipse(32, 42.5, 12.5, 10, 0)
            ellipse(16.5, 29.5, 4.6, 6.2, -22)
            ellipse(26, 19.5, 5, 6.6, -8)
            ellipse(38, 19.5, 5, 6.6, 8)
            ellipse(47.5, 29.5, 4.6, 6.2, 22)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = String(localized: "Ferret")
        return image
    }()
}
