#!/usr/bin/env swift
//
// Frames raw simulator screenshots in an Apple device bezel for the README.
//
//   swift tools/frame-screenshots.swift [path/to/bezel.png]
//
// Reads every PNG in docs/screenshots/raw/ and writes the framed copy to
// docs/screenshots/. The bezel defaults to tools/bezels/iPhone 17 Pro - Deep Blue - Portrait.png.
// Apple's bezels can't be redistributed, so tools/bezels/ is gitignored; see tools/README.md
// for where to get one.
//
// Nothing about the device is hard-coded. The screen opening is found by flood-filling the
// bezel's non-opaque pixels outward from its center, so the screenshot is clipped to the real
// rounded display shape (antialiased inner edge included) and any bezel whose opening matches
// the capture size works.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fraction of the bezel's native size to write out. The native frame is about 1350 px wide;
/// half that is still 2x for the ~300 pt width the README displays it at.
let outputScale: CGFloat = 0.5
/// Alpha at or above this counts as solid frame. Anything lower belongs to the screen opening.
let opaqueAlpha: UInt8 = 255

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let rawDir = root.appendingPathComponent("docs/screenshots/raw")
let outDir = root.appendingPathComponent("docs/screenshots")
let bezelURL = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : root.appendingPathComponent("tools/bezels/iPhone 17 Pro - Deep Blue - Portrait.png")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("frame-screenshots: \(message)\n".utf8))
    exit(1)
}

func loadImage(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("can't read \(url.path)")
    }
    return image
}

/// Draws `image` into a fresh premultiplied RGBA buffer so pixels can be read directly.
func rgbaContext(width: Int, height: Int) -> CGContext {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fail("can't allocate a \(width)x\(height) bitmap") }
    return context
}

/// The screen opening as a mask image (white = screen) plus its bounding box, in bitmap rows
/// counted from the top.
func screenOpening(of bezel: CGImage) -> (mask: CGImage, bounds: (x: Int, y: Int, w: Int, h: Int)) {
    let w = bezel.width, h = bezel.height
    let context = rgbaContext(width: w, height: h)
    context.draw(bezel, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = context.data else { fail("can't read bezel pixels") }
    let pixels = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * w + x) * 4 + 3] }

    var inside = [UInt8](repeating: 0, count: w * h)
    var stack = [(w / 2, h / 2)]
    guard alpha(w / 2, h / 2) < opaqueAlpha else { fail("bezel center is opaque; is this a portrait bezel?") }
    var minX = w, minY = h, maxX = 0, maxY = 0
    while let (x, y) = stack.popLast() {
        guard x >= 0, y >= 0, x < w, y < h, inside[y * w + x] == 0, alpha(x, y) < opaqueAlpha else { continue }
        // Reaching the image edge means the "opening" leaked to the outside of the device.
        if x == 0 || y == 0 || x == w - 1 || y == h - 1 { fail("screen opening isn't enclosed by the frame") }
        inside[y * w + x] = 255
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        stack.append((x + 1, y)); stack.append((x - 1, y)); stack.append((x, y + 1)); stack.append((x, y - 1))
    }

    // A plain DeviceGray image used with clip(to:mask:) paints where it's white.
    guard let provider = CGDataProvider(data: Data(inside) as CFData),
          let mask = CGImage(
              width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
              provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
          ) else { fail("can't build screen mask") }
    return (mask, (minX, minY, maxX - minX + 1, maxY - minY + 1))
}

let bezel = loadImage(bezelURL)
let (mask, opening) = screenOpening(of: bezel)
print("Screen opening: \(opening.w)x\(opening.h) at (\(opening.x), \(opening.y)) in a \(bezel.width)x\(bezel.height) bezel")

let raws = (try? FileManager.default.contentsOfDirectory(at: rawDir, includingPropertiesForKeys: nil))?
    .filter { $0.pathExtension.lowercased() == "png" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
guard !raws.isEmpty else { fail("no PNGs in \(rawDir.path)") }

for raw in raws {
    let shot = loadImage(raw)
    guard shot.width == opening.w, shot.height == opening.h else {
        fail("\(raw.lastPathComponent) is \(shot.width)x\(shot.height) but the bezel's screen is \(opening.w)x\(opening.h); capture on the matching simulator")
    }

    let canvas = rgbaContext(width: bezel.width, height: bezel.height)
    let full = CGRect(x: 0, y: 0, width: bezel.width, height: bezel.height)
    // Core Graphics puts the origin bottom-left; the opening was measured from the top.
    let screenRect = CGRect(x: opening.x, y: bezel.height - opening.y - opening.h, width: opening.w, height: opening.h)
    canvas.saveGState()
    canvas.clip(to: full, mask: mask)
    canvas.draw(shot, in: screenRect)
    canvas.restoreGState()
    canvas.draw(bezel, in: full)
    guard let framed = canvas.makeImage() else { fail("can't composite \(raw.lastPathComponent)") }

    let outW = Int((CGFloat(bezel.width) * outputScale).rounded())
    let outH = Int((CGFloat(bezel.height) * outputScale).rounded())
    let scaled = rgbaContext(width: outW, height: outH)
    scaled.interpolationQuality = .high
    scaled.draw(framed, in: CGRect(x: 0, y: 0, width: outW, height: outH))
    guard let output = scaled.makeImage() else { fail("can't scale \(raw.lastPathComponent)") }

    let dest = outDir.appendingPathComponent(raw.lastPathComponent)
    guard let writer = CGImageDestinationCreateWithURL(dest as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("can't write \(dest.path)")
    }
    CGImageDestinationAddImage(writer, output, nil)
    guard CGImageDestinationFinalize(writer) else { fail("can't write \(dest.path)") }
    print("Framed \(raw.lastPathComponent) -> docs/screenshots/\(raw.lastPathComponent) (\(outW)x\(outH))")
}
