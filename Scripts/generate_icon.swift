import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate_icon.swift <output.iconset>\n", stderr)
    exit(2)
}

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

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

enum IconGeneratorError: LocalizedError {
    case bitmapContext(Int)
    case image(Int)
    case destination(URL)
    case write(URL)

    var errorDescription: String? {
        switch self {
        case .bitmapContext(let size):
            return "Could not create a \(size)x\(size) bitmap context"
        case .image(let size):
            return "Could not render the \(size)x\(size) icon"
        case .destination(let url):
            return "Could not create the PNG destination at \(url.path)"
        case .write(let url):
            return "Could not write PNG data to \(url.path)"
        }
    }
}

func makeColor(
    red: CGFloat,
    green: CGFloat,
    blue: CGFloat,
    alpha: CGFloat = 1,
    colorSpace: CGColorSpace
) -> CGColor {
    CGColor(
        colorSpace: colorSpace,
        components: [red, green, blue, alpha]
    )!
}

func writeIcon(size: Int, to url: URL) throws {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue

    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: size * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo
    ) else {
        throw IconGeneratorError.bitmapContext(size)
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    let dimension = CGFloat(size)
    context.clear(CGRect(x: 0, y: 0, width: dimension, height: dimension))
    let inset = dimension * 0.045
    let backgroundRect = CGRect(
        x: inset,
        y: inset,
        width: dimension - inset * 2,
        height: dimension - inset * 2
    )
    let background = CGPath(
        roundedRect: backgroundRect,
        cornerWidth: dimension * 0.22,
        cornerHeight: dimension * 0.22,
        transform: nil
    )

    let startColor = makeColor(
        red: 0.10,
        green: 0.56,
        blue: 0.98,
        colorSpace: colorSpace
    )
    let endColor = makeColor(
        red: 0.20,
        green: 0.31,
        blue: 0.86,
        colorSpace: colorSpace
    )
    guard let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [startColor, endColor] as CFArray,
        locations: [0, 1]
    ) else {
        throw IconGeneratorError.image(size)
    }

    context.saveGState()
    context.addPath(background)
    context.clip()
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: dimension * 0.15, y: dimension * 0.85),
        end: CGPoint(x: dimension * 0.85, y: dimension * 0.15),
        options: []
    )
    context.restoreGState()

    // A simple tunnel/shield mark that remains legible at 16 px.
    let shield = CGMutablePath()
    shield.move(to: CGPoint(x: dimension * 0.50, y: dimension * 0.78))
    shield.addCurve(
        to: CGPoint(x: dimension * 0.76, y: dimension * 0.67),
        control1: CGPoint(x: dimension * 0.59, y: dimension * 0.74),
        control2: CGPoint(x: dimension * 0.68, y: dimension * 0.71)
    )
    shield.addLine(to: CGPoint(x: dimension * 0.72, y: dimension * 0.43))
    shield.addCurve(
        to: CGPoint(x: dimension * 0.50, y: dimension * 0.22),
        control1: CGPoint(x: dimension * 0.69, y: dimension * 0.32),
        control2: CGPoint(x: dimension * 0.59, y: dimension * 0.25)
    )
    shield.addCurve(
        to: CGPoint(x: dimension * 0.28, y: dimension * 0.43),
        control1: CGPoint(x: dimension * 0.41, y: dimension * 0.25),
        control2: CGPoint(x: dimension * 0.31, y: dimension * 0.32)
    )
    shield.addLine(to: CGPoint(x: dimension * 0.24, y: dimension * 0.67))
    shield.addCurve(
        to: CGPoint(x: dimension * 0.50, y: dimension * 0.78),
        control1: CGPoint(x: dimension * 0.32, y: dimension * 0.71),
        control2: CGPoint(x: dimension * 0.41, y: dimension * 0.74)
    )
    shield.closeSubpath()
    context.addPath(shield)
    context.setFillColor(makeColor(red: 1, green: 1, blue: 1, colorSpace: colorSpace))
    context.fillPath()

    let tunnel = CGPath(
        roundedRect: CGRect(
            x: dimension * 0.39,
            y: dimension * 0.37,
            width: dimension * 0.22,
            height: dimension * 0.25
        ),
        cornerWidth: dimension * 0.11,
        cornerHeight: dimension * 0.11,
        transform: nil
    )
    context.addPath(tunnel)
    context.setFillColor(makeColor(
        red: 0.14,
        green: 0.42,
        blue: 0.89,
        colorSpace: colorSpace
    ))
    context.fillPath()

    guard let image = context.makeImage() else {
        throw IconGeneratorError.image(size)
    }
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw IconGeneratorError.destination(url)
    }

    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconGeneratorError.write(url)
    }
}

do {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    for (name, size) in variants {
        try writeIcon(size: size, to: output.appendingPathComponent(name))
    }
} catch {
    fputs("Icon generation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
