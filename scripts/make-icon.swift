// Renders the DriveDock app icon and writes Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift [output.icns] [preview.png]
//
// Drawn with Core Graphics on the macOS icon grid (824 pt body on a 1024 pt canvas).
// The glyph is drawn by hand – SF Symbols may not be used in app icons.

import AppKit
import Foundation

let args = CommandLine.arguments
let icnsURL = URL(fileURLWithPath: args.count > 1 ? args[1] : "Resources/AppIcon.icns")
let previewURL = args.count > 2 ? URL(fileURLWithPath: args[2]) : nil

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

func linearGradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: locations)!
}

/// Continuous-corner rounded rectangle (close to Apple's squircle).
func squircle(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let scale = s / 1024
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)
    ctx.interpolationQuality = .high

    // MARK: Body with drop shadow
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = squircle(body, radius: 186)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0, 0, 0, 0.32))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(30, 90, 220))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    // Deep blue to bright cyan-blue, light from the top.
    ctx.drawLinearGradient(
        linearGradient([color(94, 182, 255), color(38, 110, 240), color(22, 58, 178)], [0, 0.55, 1]),
        start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft glass sheen on the upper half.
    ctx.drawRadialGradient(
        linearGradient([color(255, 255, 255, 0.28), color(255, 255, 255, 0)], [0, 1]),
        startCenter: CGPoint(x: 512, y: 1010), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 1010), endRadius: 620, options: [])
    ctx.restoreGState()

    // Fine inner rim like the system icons.
    ctx.saveGState()
    ctx.addPath(squircle(body.insetBy(dx: 2, dy: 2), radius: 184))
    ctx.setStrokeColor(color(255, 255, 255, 0.22))
    ctx.setLineWidth(4)
    ctx.strokePath()
    ctx.restoreGState()

    // MARK: Glyph – two stacked drives docked to a network line
    func drive(y: CGFloat, alpha: CGFloat) {
        let rect = CGRect(x: 262, y: y, width: 500, height: 150)
        let path = squircle(rect, radius: 42)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: color(5, 25, 90, 0.35))
        ctx.addPath(path)
        ctx.setFillColor(color(255, 255, 255, alpha))
        ctx.fillPath()
        ctx.restoreGState()

        // Subtle vertical shading on the slab.
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.drawLinearGradient(
            linearGradient([color(255, 255, 255, 0), color(170, 200, 255, 0.35)], [0, 1]),
            start: CGPoint(x: 512, y: rect.maxY), end: CGPoint(x: 512, y: rect.minY), options: [])
        ctx.restoreGState()

        // Vent slots on the left.
        ctx.setFillColor(color(40, 95, 215, 0.55))
        for i in 0..<3 {
            let slot = CGRect(x: 310 + CGFloat(i) * 46, y: rect.midY - 34, width: 22, height: 68)
            ctx.addPath(squircle(slot, radius: 11))
            ctx.fillPath()
        }
        // Status light on the right.
        let led = CGRect(x: 664, y: rect.midY - 24, width: 48, height: 48)
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 22, color: color(60, 230, 140, 0.9))
        ctx.setFillColor(color(52, 211, 120))
        ctx.fillEllipse(in: led)
        ctx.restoreGState()
        ctx.setFillColor(color(255, 255, 255, 0.55))
        ctx.fillEllipse(in: CGRect(x: led.minX + 12, y: led.midY + 2, width: 16, height: 12))
    }

    // Connector from the drives down to the network line with three nodes
    // (drawn first, so it tucks under the lower drive).
    ctx.setFillColor(color(255, 255, 255, 0.95))
    ctx.addPath(squircle(CGRect(x: 494, y: 262, width: 36, height: 180), radius: 18))
    ctx.fillPath()
    ctx.addPath(squircle(CGRect(x: 262, y: 246, width: 500, height: 32), radius: 16))
    ctx.fillPath()
    for x in [278.0, 512.0, 746.0] {
        let r: CGFloat = x == 512 ? 40 : 30
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -4), blur: 10, color: color(5, 25, 90, 0.3))
        ctx.setFillColor(color(255, 255, 255))
        ctx.fillEllipse(in: CGRect(x: x - r, y: 262 - r, width: r * 2, height: r * 2))
        ctx.restoreGState()
        ctx.setFillColor(color(38, 110, 240))
        ctx.fillEllipse(in: CGRect(x: x - r * 0.45, y: 262 - r * 0.45, width: r * 0.9, height: r * 0.9))
    }

    drive(y: 610, alpha: 0.92)
    drive(y: 430, alpha: 1.0)

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    try data.write(to: url)
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

for base in [16, 32, 128, 256, 512] {
    try writePNG(drawIcon(size: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try writePNG(drawIcon(size: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if let previewURL {
    try writePNG(drawIcon(size: 1024), to: previewURL)
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icnsURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write("iconutil failed\n".data(using: .utf8)!)
    exit(1)
}
print("Wrote \(icnsURL.path)")
