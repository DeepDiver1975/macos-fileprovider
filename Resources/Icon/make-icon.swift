#!/usr/bin/env swift

// Regenerates Resources/Assets.xcassets/AppIcon.appiconset from the upstream
// ownCloud logo (issue #18). Run via `make icons` from the repository root; the
// generated PNGs are committed, so this only needs re-running when the artwork or
// the sizing constants below change.
//
// Why a script rather than a checked-in .icns: the input is the official brand
// SVG (see README.md in this directory) and every derived pixel is reproducible
// from it, so both the source and the output stay reviewable.
//
// Why AppKit rather than qlmanage/sips: `qlmanage -t` forces square output *and*
// composites onto opaque white, which silently destroys the squircle's
// transparent corners. NSImage loads the SVG as an _NSSVGImageRep and drawing it
// into an NSBitmapImageRep preserves alpha. This also keeps the script free of
// Homebrew dependencies — neither ImageMagick nor rsvg-convert is assumed.

import AppKit
import Foundation

// MARK: - Layout constants

/// Index of the cloud-mark path in the upstream SVG. Paths 0...7 are the
/// "ownCloud" wordmark, which we deliberately drop: it is illegible at the 16 px
/// the Finder sidebar renders sync roots at.
let cloudPathIndex = 8

/// ownCloud dark blue, the single fill used by the 1c-blue logo variant.
let brandBlue = "#041E42"

/// Apple's macOS icon grid: the art sits in an 824/1024 rounded square with a
/// 185/824 corner radius, leaving the surrounding margin the system expects.
let squircleFraction = 824.0 / 1024.0
let cornerRadiusFraction = 185.0 / 824.0

/// The cloud is much wider than it is tall, so it is scaled to a fraction of the
/// canvas *width* — matching on height would leave it looking undersized.
let cloudWidthFraction = 0.78

/// The ten representations a macOS app icon needs, as (points, scale).
let variants: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
    (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
]

// MARK: - Paths

let iconDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let resourcesDirectory = iconDirectory.deletingLastPathComponent()
let sourceSVG = iconDirectory.appendingPathComponent("oc-logo-1c-blue-RGB.svg")
let appIconSet = resourcesDirectory
    .appendingPathComponent("Assets.xcassets")
    .appendingPathComponent("AppIcon.appiconset")

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("make-icon: \(message)\n".utf8))
    exit(1)
}

// MARK: - Reading the upstream artwork

/// The `d` attribute of every `<path>` in the SVG, in document order.
func pathData(in svg: String) -> [String] {
    let pattern = try! NSRegularExpression(pattern: "<path[^>]*d=\"([^\"]*)\"")
    let range = NSRange(svg.startIndex..., in: svg)
    return pattern.matches(in: svg, range: range).compactMap { match in
        Range(match.range(at: 1), in: svg).map { String(svg[$0]) }
    }
}

/// The bounding box of an SVG path.
///
/// Every coordinate the path visits is accumulated, Bézier control points
/// included. That over-estimates the true bounds slightly — a curve stays inside
/// its control hull — which is the safe direction to err: the mark can only end
/// up marginally smaller than the target fraction, never clipped.
func boundingBox(ofPath d: String) -> CGRect {
    let pattern = try! NSRegularExpression(
        pattern: "[MmLlHhVvCcSsQqTtAaZz]|-?\\d*\\.?\\d+(?:[eE]-?\\d+)?")
    let range = NSRange(d.startIndex..., in: d)
    let tokens = pattern.matches(in: d, range: range).compactMap { match in
        Range(match.range, in: d).map { String(d[$0]) }
    }

    // Argument count per command, keyed by its uppercase (absolute) form.
    let argumentCount: [Character: Int] = [
        "M": 2, "L": 2, "H": 1, "V": 1, "C": 6, "S": 4, "Q": 4, "T": 2, "A": 7, "Z": 0,
    ]

    var minX = Double.greatestFiniteMagnitude, minY = Double.greatestFiniteMagnitude
    var maxX = -Double.greatestFiniteMagnitude, maxY = -Double.greatestFiniteMagnitude
    var x = 0.0, y = 0.0
    var command: Character = "M"
    var index = 0

    func visit(_ px: Double, _ py: Double) {
        minX = min(minX, px); maxX = max(maxX, px)
        minY = min(minY, py); maxY = max(maxY, py)
    }

    while index < tokens.count {
        let token = tokens[index]
        if let letter = token.first, letter.isLetter {
            command = letter
            index += 1
            continue
        }
        let absolute = Character(command.uppercased())
        guard let count = argumentCount[absolute] else { fail("unknown path command \(command)") }
        let isRelative = command.isLowercase
        let args = tokens[index..<min(index + count, tokens.count)].compactMap(Double.init)
        guard args.count == count else { break }
        index += count

        switch absolute {
        case "H":
            x = isRelative ? x + args[0] : args[0]
        case "V":
            y = isRelative ? y + args[0] : args[0]
        case "A":
            // Only the endpoint matters here; the arc itself stays within the
            // radii, which the over-estimate above already tolerates.
            x = isRelative ? x + args[5] : args[5]
            y = isRelative ? y + args[6] : args[6]
        default:
            for pair in stride(from: 0, to: count, by: 2) {
                let px = isRelative ? x + args[pair] : args[pair]
                let py = isRelative ? y + args[pair + 1] : args[pair + 1]
                visit(px, py)
                if pair == count - 2 { x = px; y = py }
            }
        }
        visit(x, y)

        // An implicit repeat of moveto arguments is a lineto, per the SVG spec.
        if absolute == "M" { command = isRelative ? "l" : "L" }
    }

    guard minX <= maxX, minY <= maxY else { fail("could not determine the cloud's bounding box") }
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}

// MARK: - Composing the square icon

/// A square SVG holding the white squircle and the centred cloud mark, expressed
/// in the source artwork's user-space so the original path can be reused verbatim.
func squareIconSVG(cloudPath: String, cloudBounds: CGRect) -> String {
    // Choose a canvas whose width is `cloudWidthFraction` of the cloud's width,
    // then centre the cloud in it.
    let side = cloudBounds.width / cloudWidthFraction
    let originX = cloudBounds.minX - (side - cloudBounds.width) / 2
    let originY = cloudBounds.minY - (side - cloudBounds.height) / 2

    let squircleSide = side * squircleFraction
    let radius = squircleSide * cornerRadiusFraction
    let squircleX = originX + (side - squircleSide) / 2
    let squircleY = originY + (side - squircleSide) / 2

    func f(_ value: Double) -> String { String(format: "%.3f", value) }

    return """
        <?xml version="1.0" encoding="UTF-8"?>
        <svg xmlns="http://www.w3.org/2000/svg" \
        viewBox="\(f(originX)) \(f(originY)) \(f(side)) \(f(side))" width="1024" height="1024">
          <rect x="\(f(squircleX))" y="\(f(squircleY))" \
        width="\(f(squircleSide))" height="\(f(squircleSide))" \
        rx="\(f(radius))" ry="\(f(radius))" fill="#FFFFFF"/>
          <path fill="\(brandBlue)" d="\(cloudPath)"/>
        </svg>
        """
}

/// Rasterize `image` into a `pixels`-square PNG.
func png(of image: NSImage, pixels: Int) -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)
    else { fail("could not allocate a \(pixels)px bitmap") }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        fail("could not encode the \(pixels)px PNG")
    }
    return data
}

func filename(points: Int, scale: Int) -> String {
    "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
}

/// The appiconset manifest actool reads.
func contentsJSON() -> Data {
    let images = variants.map { variant in
        """
            {
              "size" : "\(variant.points)x\(variant.points)",
              "idiom" : "mac",
              "scale" : "\(variant.scale)x",
              "filename" : "\(filename(points: variant.points, scale: variant.scale))"
            }
        """
    }
    let json = """
        {
          "images" : [
        \(images.joined(separator: ",\n"))
          ],
          "info" : {
            "author" : "xcode",
            "version" : 1
          }
        }

        """
    return Data(json.utf8)
}

// MARK: - Main

guard let svg = try? String(contentsOf: sourceSVG, encoding: .utf8) else {
    fail("could not read \(sourceSVG.path)")
}

let paths = pathData(in: svg)
guard paths.indices.contains(cloudPathIndex) else {
    fail("expected at least \(cloudPathIndex + 1) paths in the logo, found \(paths.count) — "
        + "the upstream artwork changed; re-check which path is the cloud mark")
}
let cloudPath = paths[cloudPathIndex]
let cloudBounds = boundingBox(ofPath: cloudPath)

// The cloud is markedly wider than tall; if that no longer holds we have almost
// certainly picked up a wordmark path instead of the mark.
guard cloudBounds.width > cloudBounds.height else {
    fail("path \(cloudPathIndex) is not the wide cloud mark (bounds \(cloudBounds)) — "
        + "re-check the upstream artwork")
}

let iconSVG = squareIconSVG(cloudPath: cloudPath, cloudBounds: cloudBounds)
guard let image = NSImage(data: Data(iconSVG.utf8)) else {
    fail("AppKit could not rasterize the composed SVG")
}
image.size = NSSize(width: 1024, height: 1024)

try? FileManager.default.createDirectory(at: appIconSet, withIntermediateDirectories: true)
for variant in variants {
    let name = filename(points: variant.points, scale: variant.scale)
    let data = png(of: image, pixels: variant.points * variant.scale)
    do {
        try data.write(to: appIconSet.appendingPathComponent(name))
    } catch {
        fail("could not write \(name): \(error.localizedDescription)")
    }
}
do {
    try contentsJSON().write(to: appIconSet.appendingPathComponent("Contents.json"))
} catch {
    fail("could not write Contents.json: \(error.localizedDescription)")
}

print("make-icon: wrote \(variants.count) PNGs + Contents.json to \(appIconSet.path)")
print("make-icon: cloud bounds in source user-space \(cloudBounds)")
