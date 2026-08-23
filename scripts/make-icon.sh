#!/usr/bin/env swift
// Generates Resources/AppIcon.icns.
//
// Drawn in code rather than shipped as a binary blob so the mark can be tweaked
// in a diff. Run: ./scripts/make-icon.swift  (needs iconutil, which CLT provides)
import AppKit
import CoreGraphics
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let out = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func draw(size: Int) -> Data? {
    let s = CGFloat(size)
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    // macOS app icons sit inset inside their canvas.
    let inset = s * 0.085
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = rect.width * 0.225
    let body = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
        colors: [
            CGColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1),
            CGColor(red: 0.04, green: 0.04, blue: 0.04, alpha: 1)
        ] as CFArray,
        locations: [0, 1]
    )!
    ctx.drawLinearGradient(gradient,
                           start: CGPoint(x: 0, y: rect.maxY),
                           end: CGPoint(x: 0, y: rect.minY),
                           options: [])
    ctx.restoreGState()

    // Hairline edge so it reads against a dark Dock.
    ctx.addPath(body)
    ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.10))
    ctx.setLineWidth(max(1, s * 0.005))
    ctx.strokePath()

    // Waveform: five capsules, tallest in the middle.
    let weights: [CGFloat] = [0.34, 0.66, 1.0, 0.66, 0.34]
    let barWidth = rect.width * 0.072
    let gap = rect.width * 0.062
    let total = barWidth * 5 + gap * 4
    let maxHeight = rect.height * 0.52
    var x = rect.midX - total / 2

    for (index, weight) in weights.enumerated() {
        let h = max(barWidth, maxHeight * weight)
        let bar = CGRect(x: x, y: rect.midY - h / 2, width: barWidth, height: h)
        let path = CGPath(roundedRect: bar, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
        ctx.addPath(path)
        // Centre bar carries the one accent colour in the whole product.
        ctx.setFillColor(index == 2
            ? CGColor(red: 0.620, green: 0.482, blue: 1.000, alpha: 1)
            : CGColor(red: 0.925, green: 0.925, blue: 0.925, alpha: 1))
        ctx.fillPath()
        x += barWidth + gap
    }

    guard let image = ctx.makeImage() else { return nil }
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])
}

for size in sizes {
    guard let data = draw(size: size) else { continue }
    let scale1 = out.appendingPathComponent("icon_\(size)x\(size).png")
    try? data.write(to: scale1)
    // @2x slot for the half-size entry.
    if size >= 32 {
        let half = size / 2
        let scale2 = out.appendingPathComponent("icon_\(half)x\(half)@2x.png")
        try? data.write(to: scale2)
    }
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", out.path, "-o", "Resources/AppIcon.icns"]
try task.run()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "wrote Resources/AppIcon.icns" : "iconutil failed")
