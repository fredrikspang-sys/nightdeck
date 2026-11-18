#!/usr/bin/env swift
// Draws Nightdeck's app icon (a play mark on the night background) and packs AppIcon.icns.
// Usage: swift scripts/make-icon.swift <AppIcon.icns> [preview.png]
import AppKit
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    fputs("usage: make-icon.swift <AppIcon.icns> [preview.png]\n", stderr)
    exit(1)
}

let output = URL(fileURLWithPath: args[1])
let preview = args.count >= 3 ? URL(fileURLWithPath: args[2]) : nil

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: [r, g, b, a])!
}

func png(_ pixels: Int) -> Data {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fputs("could not make a bitmap\n", stderr)
        exit(1)
    }
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high
    draw(ctx, CGFloat(pixels))
    guard let image = ctx.makeImage() else {
        fputs("could not read the bitmap\n", stderr)
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fputs("could not encode png\n", stderr)
        exit(1)
    }
    return data
}

func draw(_ ctx: CGContext, _ size: CGFloat) {
    let s = size / 1024
    func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

    let top = color(0.15, 0.17, 0.23)
    let bottom = color(0.045, 0.05, 0.065)
    if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [top, bottom] as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient, start: P(0, 1024), end: P(0, 0), options: [])
    }

    // Warm glow behind the play mark. It stays faint so 16 px still reads as one shape.
    if let glow = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0.95, 0.58, 0.22, 0.32), color(0.95, 0.58, 0.22, 0)] as CFArray,
        locations: [0, 1]
    ) {
        ctx.drawRadialGradient(glow, startCenter: P(560, 500), startRadius: 0, endCenter: P(560, 500), endRadius: 520 * s, options: [])
    }

    // Centroid sits on the icon center. The tip is to the right, so the mass looks centered.
    let points = [P(318, 884), P(900, 512), P(318, 140)]
    let path = roundedPolygon(points, radius: 72 * s)
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let light = color(0.98, 0.97, 0.96)
    let warm = color(0.98, 0.78, 0.48)
    if let fill = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [light, warm] as CFArray, locations: [0.2, 1]) {
        ctx.drawLinearGradient(fill, start: P(318, 720), end: P(900, 380), options: [])
    } else {
        ctx.setFillColor(light)
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    }
    ctx.restoreGState()
}

/// Convex polygon with quadratic corners. `radius` is trimmed so adjacent corners do not meet.
func roundedPolygon(_ points: [CGPoint], radius: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let count = points.count
    guard count >= 3 else { return path }
    struct Corner {
        var start: CGPoint
        var end: CGPoint
        var vertex: CGPoint
    }
    var corners: [Corner] = []
    for index in 0..<count {
        let previous = points[(index + count - 1) % count]
        let current = points[index]
        let next = points[(index + 1) % count]
        let toPrevious = CGPoint(x: previous.x - current.x, y: previous.y - current.y)
        let toNext = CGPoint(x: next.x - current.x, y: next.y - current.y)
        let previousLength = hypot(toPrevious.x, toPrevious.y)
        let nextLength = hypot(toNext.x, toNext.y)
        guard previousLength > 0.001, nextLength > 0.001 else { continue }
        let unitPrevious = CGPoint(x: toPrevious.x / previousLength, y: toPrevious.y / previousLength)
        let unitNext = CGPoint(x: toNext.x / nextLength, y: toNext.y / nextLength)
        let dot = max(-1, min(1, unitPrevious.x * unitNext.x + unitPrevious.y * unitNext.y))
        let half = acos(dot) / 2
        let tangent = tan(half)
        var trim = tangent > 0.001 ? radius / tangent : 0
        trim = min(trim, min(previousLength, nextLength) * 0.45)
        corners.append(Corner(
            start: CGPoint(x: current.x + unitPrevious.x * trim, y: current.y + unitPrevious.y * trim),
            end: CGPoint(x: current.x + unitNext.x * trim, y: current.y + unitNext.y * trim),
            vertex: current
        ))
    }
    guard let first = corners.first else { return path }
    path.move(to: first.start)
    for corner in corners {
        path.addLine(to: corner.start)
        path.addQuadCurve(to: corner.end, control: corner.vertex)
    }
    path.closeSubpath()
    return path
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

let iconsetRoot = FileManager.default.temporaryDirectory.appendingPathComponent("nightdeck-icon-\(UUID().uuidString)", isDirectory: true)
let iconset = iconsetRoot.appendingPathComponent("Nightdeck.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconsetRoot) }

for (name, pixels) in sizes {
    try png(pixels).write(to: iconset.appendingPathComponent(name))
}
if let preview {
    try png(1024).write(to: preview)
}

let tool = Process()
tool.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
tool.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try tool.run()
tool.waitUntilExit()
guard tool.terminationStatus == 0 else {
    fputs("iconutil failed\n", stderr)
    exit(tool.terminationStatus)
}
