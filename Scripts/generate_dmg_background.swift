import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else {
    fputs("Usage: generate_dmg_background.swift <output.png>\n", stderr)
    exit(2)
}

let width = 600
let height = 360
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!
}

guard let context = CGContext(
    data: nil,
    width: width,
    height: height,
    bitsPerComponent: 8,
    bytesPerRow: width * 4,
    space: colorSpace,
    bitmapInfo: bitmapInfo
) else {
    fatalError("Could not create DMG background context")
}

let bounds = CGRect(x: 0, y: 0, width: width, height: height)
let gradient = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(0.96, 0.98, 1), color(0.88, 0.93, 1)] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    gradient,
    start: CGPoint(x: 0, y: CGFloat(height)),
    end: CGPoint(x: CGFloat(width), y: 0),
    options: []
)

context.setFillColor(color(1, 1, 1, 0.72))
context.addPath(CGPath(roundedRect: bounds.insetBy(dx: 22, dy: 22), cornerWidth: 22, cornerHeight: 22, transform: nil))
context.fillPath()

func drawText(_ text: String, size: CGFloat, weight: CTFontSymbolicTraits, y: CGFloat, color textColor: CGColor) {
    let baseFont = CTFontCreateWithName("Helvetica Neue" as CFString, size, nil)
    let font = CTFontCreateCopyWithSymbolicTraits(baseFont, 0, nil, weight, weight) ?? baseFont
    let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): textColor
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    let lineBounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
    context.textPosition = CGPoint(x: (CGFloat(width) - lineBounds.width) / 2, y: y)
    CTLineDraw(line, context)
}

drawText("Maos VPN", size: 27, weight: .boldTrait, y: 294, color: color(0.10, 0.18, 0.29))
drawText("Drag to Applications  •  Перетащите в Программы", size: 14, weight: [], y: 264, color: color(0.34, 0.40, 0.49))

context.setStrokeColor(color(0.12, 0.48, 0.92, 0.92))
context.setLineWidth(7)
context.setLineCap(.round)
context.move(to: CGPoint(x: 255, y: 142))
context.addLine(to: CGPoint(x: 345, y: 142))
context.strokePath()
context.setFillColor(color(0.12, 0.48, 0.92, 0.92))
context.move(to: CGPoint(x: 365, y: 142))
context.addLine(to: CGPoint(x: 337, y: 160))
context.addLine(to: CGPoint(x: 337, y: 124))
context.closePath()
context.fillPath()

guard let image = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
    fatalError("Could not prepare DMG background PNG")
}
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Could not write DMG background PNG") }
