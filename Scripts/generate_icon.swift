import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate_icon.swift <output.iconset>\n", stderr)
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func drawIcon(size: Int) throws -> Data {
    let dimension = CGFloat(size)
    let image = NSImage(size: NSSize(width: dimension, height: dimension))
    image.lockFocus()
    defer { image.unlockFocus() }

    let inset = dimension * 0.045
    let backgroundRect = NSRect(x: inset, y: inset, width: dimension - inset * 2, height: dimension - inset * 2)
    let background = NSBezierPath(roundedRect: backgroundRect, xRadius: dimension * 0.22, yRadius: dimension * 0.22)
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.10, green: 0.56, blue: 0.98, alpha: 1),
        ending: NSColor(calibratedRed: 0.20, green: 0.31, blue: 0.86, alpha: 1)
    )!
    gradient.draw(in: background, angle: -55)

    // A simple tunnel/shield mark that remains legible at 16 px.
    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: dimension * 0.50, y: dimension * 0.78))
    shield.curve(to: NSPoint(x: dimension * 0.76, y: dimension * 0.67), controlPoint1: NSPoint(x: dimension * 0.59, y: dimension * 0.74), controlPoint2: NSPoint(x: dimension * 0.68, y: dimension * 0.71))
    shield.line(to: NSPoint(x: dimension * 0.72, y: dimension * 0.43))
    shield.curve(to: NSPoint(x: dimension * 0.50, y: dimension * 0.22), controlPoint1: NSPoint(x: dimension * 0.69, y: dimension * 0.32), controlPoint2: NSPoint(x: dimension * 0.59, y: dimension * 0.25))
    shield.curve(to: NSPoint(x: dimension * 0.28, y: dimension * 0.43), controlPoint1: NSPoint(x: dimension * 0.41, y: dimension * 0.25), controlPoint2: NSPoint(x: dimension * 0.31, y: dimension * 0.32))
    shield.line(to: NSPoint(x: dimension * 0.24, y: dimension * 0.67))
    shield.curve(to: NSPoint(x: dimension * 0.50, y: dimension * 0.78), controlPoint1: NSPoint(x: dimension * 0.32, y: dimension * 0.71), controlPoint2: NSPoint(x: dimension * 0.41, y: dimension * 0.74))
    shield.close()
    NSColor.white.setFill()
    shield.fill()

    let tunnel = NSBezierPath(roundedRect: NSRect(x: dimension * 0.39, y: dimension * 0.37, width: dimension * 0.22, height: dimension * 0.25), xRadius: dimension * 0.11, yRadius: dimension * 0.11)
    NSColor(calibratedRed: 0.14, green: 0.42, blue: 0.89, alpha: 1).setFill()
    tunnel.fill()

    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "IconGenerator", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not render PNG"])
    }
    return png
}

for (name, size) in variants {
    try drawIcon(size: size).write(to: output.appendingPathComponent(name), options: .atomic)
}
