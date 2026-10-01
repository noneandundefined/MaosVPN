import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: generate_icon.swift <source.png> <output.iconset>\n", stderr)
    exit(2)
}

let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

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
    case source(URL)
    case thumbnail(Int)
    case invalidSize(expected: Int, width: Int, height: Int)
    case destination(URL)
    case write(URL)

    var errorDescription: String? {
        switch self {
        case .source(let url):
            return "Could not read the source icon at \(url.path)"
        case .thumbnail(let size):
            return "Could not render the \(size)x\(size) icon"
        case .invalidSize(let expected, let width, let height):
            return "Rendered icon is \(width)x\(height), expected \(expected)x\(expected)"
        case .destination(let url):
            return "Could not create the PNG destination at \(url.path)"
        case .write(let url):
            return "Could not write PNG data to \(url.path)"
        }
    }
}

func writeIcon(source: CGImageSource, size: Int, to url: URL) throws {
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: size,
        kCGImageSourceShouldCacheImmediately: true
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw IconGeneratorError.thumbnail(size)
    }
    guard image.width == size, image.height == size else {
        throw IconGeneratorError.invalidSize(expected: size, width: image.width, height: image.height)
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
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
        throw IconGeneratorError.source(sourceURL)
    }
    try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
    for (name, size) in variants {
        try writeIcon(source: source, size: size, to: outputURL.appendingPathComponent(name))
    }
} catch {
    fputs("Icon generation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
