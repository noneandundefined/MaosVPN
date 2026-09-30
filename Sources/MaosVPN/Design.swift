import AppKit

enum Design {
    static let headerHeight: CGFloat = 56
    static let background = adaptive(
        "Background",
        light: NSColor(calibratedRed: 0.965, green: 0.973, blue: 0.984, alpha: 1),
        dark: NSColor(calibratedRed: 0.075, green: 0.085, blue: 0.105, alpha: 1)
    )
    static let surface = adaptive(
        "Surface",
        light: .white,
        dark: NSColor(calibratedRed: 0.115, green: 0.125, blue: 0.15, alpha: 1)
    )
    static let cardBorder = adaptive(
        "CardBorder",
        light: NSColor(calibratedRed: 0.898, green: 0.914, blue: 0.937, alpha: 1),
        dark: NSColor(calibratedRed: 0.22, green: 0.235, blue: 0.27, alpha: 1)
    )
    static let accent = NSColor(calibratedRed: 0.145, green: 0.388, blue: 0.922, alpha: 1)
    static let primaryText = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let tertiaryText = NSColor.tertiaryLabelColor
    static let hairline = NSColor.separatorColor
    static let badgeFill = adaptive(
        "BadgeFill",
        light: NSColor(calibratedRed: 0.925, green: 0.937, blue: 0.953, alpha: 1),
        dark: NSColor(calibratedRed: 0.18, green: 0.195, blue: 0.23, alpha: 1)
    )
    static let latency = NSColor(calibratedRed: 0.18, green: 0.72, blue: 0.38, alpha: 1)
    static let switchOff = adaptive(
        "SwitchOff",
        light: NSColor(calibratedRed: 0.86, green: 0.88, blue: 0.90, alpha: 1),
        dark: NSColor(calibratedRed: 0.30, green: 0.32, blue: 0.36, alpha: 1)
    )
    static let mapDot = adaptive(
        "MapDot",
        light: NSColor(calibratedRed: 0.55, green: 0.70, blue: 0.88, alpha: 0.42),
        dark: NSColor(calibratedRed: 0.38, green: 0.58, blue: 0.90, alpha: 0.28)
    )
    static let danger = NSColor(calibratedRed: 0.86, green: 0.22, blue: 0.20, alpha: 1)
    static let gold = NSColor(calibratedRed: 0.95, green: 0.72, blue: 0.20, alpha: 1)
    static let purple = NSColor(calibratedRed: 0.56, green: 0.38, blue: 0.86, alpha: 1)

    static let whiteCrown = crown(NSColor.white)
    static let goldCrown = crown(gold)
    static let purpleCrown = crown(purple)
    static let globe = strokeIcon(secondaryText, Self.drawGlobe)
    static let shield = strokeIcon(secondaryText, Self.drawShield)
    static let hiddenEye = strokeIcon(secondaryText, Self.drawHiddenEye)

    private static func adaptive(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: NSColor.Name("app.maosvpn.\(name)")) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static func crown(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        color.setFill()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 1.6, y: 6.2))
        path.line(to: NSPoint(x: 4.2, y: 13.2))
        path.line(to: NSPoint(x: 8, y: 8.2))
        path.line(to: NSPoint(x: 11.8, y: 13.2))
        path.line(to: NSPoint(x: 14.4, y: 6.2))
        path.close()
        path.fill()
        NSBezierPath(roundedRect: NSRect(x: 1.8, y: 2.2, width: 12.4, height: 2.6), xRadius: 0.6, yRadius: 0.6).fill()
        image.unlockFocus()
        return image
    }

    private static func strokeIcon(_ color: NSColor, _ draw: (NSColor) -> Void) -> NSImage {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        draw(color)
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private static func drawGlobe(_ color: NSColor) {
        color.setStroke()
        let ring = NSBezierPath(ovalIn: NSRect(x: 1.4, y: 1.4, width: 13.2, height: 13.2))
        ring.lineWidth = 1.35
        ring.stroke()
        let meridian = NSBezierPath(ovalIn: NSRect(x: 5.3, y: 1.4, width: 5.4, height: 13.2))
        meridian.lineWidth = 1.15
        meridian.stroke()
        let equator = NSBezierPath()
        equator.move(to: NSPoint(x: 1.6, y: 8))
        equator.line(to: NSPoint(x: 14.4, y: 8))
        equator.lineWidth = 1.15
        equator.stroke()
    }

    private static func drawShield(_ color: NSColor) {
        color.setStroke()
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 8, y: 1.6))
        path.line(to: NSPoint(x: 13.4, y: 3.8))
        path.line(to: NSPoint(x: 13.4, y: 8))
        path.curve(to: NSPoint(x: 8, y: 14.4), controlPoint1: NSPoint(x: 13.4, y: 11.4), controlPoint2: NSPoint(x: 11, y: 13.6))
        path.curve(to: NSPoint(x: 2.6, y: 8), controlPoint1: NSPoint(x: 5, y: 13.6), controlPoint2: NSPoint(x: 2.6, y: 11.4))
        path.line(to: NSPoint(x: 2.6, y: 3.8))
        path.close()
        path.lineWidth = 1.35
        path.stroke()
    }

    private static func drawHiddenEye(_ color: NSColor) {
        color.setStroke()
        let eye = NSBezierPath()
        eye.move(to: NSPoint(x: 1.2, y: 8))
        eye.curve(to: NSPoint(x: 14.8, y: 8), controlPoint1: NSPoint(x: 4, y: 12.4), controlPoint2: NSPoint(x: 12, y: 12.4))
        eye.curve(to: NSPoint(x: 1.2, y: 8), controlPoint1: NSPoint(x: 12, y: 3.6), controlPoint2: NSPoint(x: 4, y: 3.6))
        eye.lineWidth = 1.3
        eye.stroke()
        let pupil = NSBezierPath(ovalIn: NSRect(x: 6.3, y: 6.3, width: 3.4, height: 3.4))
        pupil.lineWidth = 1.2
        pupil.stroke()
        let slash = NSBezierPath()
        slash.move(to: NSPoint(x: 3, y: 3))
        slash.line(to: NSPoint(x: 13, y: 13))
        slash.lineWidth = 1.35
        slash.lineCapStyle = .round
        slash.stroke()
    }
}
