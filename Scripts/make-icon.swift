// Draws the PhoneCam app icon and writes every size into App/Assets.xcassets/AppIcon.appiconset.
// Run from the project root: swift Scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func drawIcon() {
    guard let context = NSGraphicsContext.current?.cgContext else { return }

    // Squircle background on the macOS icon grid (824 pt tile, 100 pt margin).
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 186, yRadius: 186)
    context.saveGState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(0x1B3A8C).setFill()
    tilePath.fill()
    context.restoreGState()

    context.saveGState()
    tilePath.addClip()
    NSGradient(colors: [color(0x3D7BFF), color(0x1C3FA8), color(0x111B4D)],
               atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
        .draw(in: tile, angle: -60)
    // Soft glow behind the phone.
    NSGradient(colors: [color(0x9CC4FF, 0.45), color(0x9CC4FF, 0)])!
        .draw(fromCenter: NSPoint(x: 512, y: 560), radius: 0, toCenter: NSPoint(x: 512, y: 560), radius: 380, options: [])

    // Phone, back side, tilted.
    context.translateBy(x: 512, y: 540)
    context.rotate(by: -10 * .pi / 180)

    // USB-C cable leaving the plug at the bottom of the phone.
    let cable = NSBezierPath()
    cable.move(to: NSPoint(x: 0, y: -340))
    cable.curve(to: NSPoint(x: 150, y: -560), controlPoint1: NSPoint(x: 0, y: -440), controlPoint2: NSPoint(x: 150, y: -440))
    cable.lineCapStyle = .round
    cable.lineWidth = 36
    color(0x0B1236, 0.9).setStroke()
    cable.stroke()
    cable.lineWidth = 24
    color(0xE9EDF5).setStroke()
    cable.stroke()
    let body = NSRect(x: -180, y: -320, width: 360, height: 640)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 70, yRadius: 70)
    context.saveGState()
    let phoneShadow = NSShadow()
    phoneShadow.shadowColor = color(0x050A24, 0.55)
    phoneShadow.shadowBlurRadius = 40
    phoneShadow.shadowOffset = NSSize(width: 14, height: -24)
    phoneShadow.set()
    color(0xF2F4F8).setFill()
    bodyPath.fill()
    context.restoreGState()
    NSGradient(colors: [color(0xFFFFFF), color(0xDCE2EC)])!.draw(in: bodyPath, angle: -70)
    color(0xB9C2D3).setStroke()
    bodyPath.lineWidth = 6
    bodyPath.stroke()

    // USB-C plug on the bottom edge.
    let plug = NSBezierPath(roundedRect: NSRect(x: -34, y: -352, width: 68, height: 44), xRadius: 14, yRadius: 14)
    color(0x9AA4B8).setFill()
    plug.fill()

    // Camera island with three lenses.
    let island = NSRect(x: -140, y: 20, width: 150, height: 270)
    let islandPath = NSBezierPath(roundedRect: island, xRadius: 75, yRadius: 75)
    color(0x1A2033).setFill()
    islandPath.fill()
    for (index, centerY) in [236.0, 155.0, 74.0].enumerated() {
        let center = NSPoint(x: -65, y: centerY)
        let outer = NSBezierPath(ovalIn: NSRect(x: center.x - 38, y: center.y - 38, width: 76, height: 76))
        color(0x3A4258).setFill()
        outer.fill()
        let glass = NSBezierPath(ovalIn: NSRect(x: center.x - 28, y: center.y - 28, width: 56, height: 56))
        NSGradient(colors: [color(index == 0 ? 0x2D5BD6 : 0x24356E), color(0x05070F)])!
            .draw(in: glass, relativeCenterPosition: NSPoint(x: -0.3, y: 0.3))
        let glint = NSBezierPath(ovalIn: NSRect(x: center.x - 16, y: center.y + 4, width: 15, height: 12))
        color(0xFFFFFF, 0.75).setFill()
        glint.fill()
    }

    // Flash and a red "live" dot.
    color(0xF7E7B5).setFill()
    NSBezierPath(ovalIn: NSRect(x: 50, y: 248, width: 34, height: 34)).fill()
    let live = NSRect(x: 60, y: -250, width: 92, height: 92)
    color(0xFFFFFF).setFill()
    NSBezierPath(ovalIn: live.insetBy(dx: -10, dy: -10)).fill()
    NSGradient(colors: [color(0xFF5A5F), color(0xD81B2B)])!
        .draw(in: NSBezierPath(ovalIn: live), relativeCenterPosition: NSPoint(x: -0.3, y: 0.3))
    context.restoreGState()
}

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: canvas, height: canvas)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let output = URL(fileURLWithPath: "App/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(pixels: points * scale).write(to: output.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
let assetsInfo: [String: Any] = ["info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: assetsInfo, options: [.prettyPrinted])
    .write(to: output.deletingLastPathComponent().appendingPathComponent("Contents.json"))
try render(pixels: 1024).write(to: URL(fileURLWithPath: "Docs/icon.png"))
print("Wrote \(images.count) icon sizes")
