import AppKit
import Foundation

let fileManager = FileManager.default
let root = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let iconset = root.appendingPathComponent("assets/MenuBarSpotify.iconset", isDirectory: true)
try? fileManager.removeItem(at: iconset)
try fileManager.createDirectory(at: iconset, withIntermediateDirectories: true)

let sizes = [16, 32, 128, 256, 512]
for size in sizes {
    try writePNG(size: size, name: "icon_\(size)x\(size).png")
    try writePNG(size: size * 2, name: "icon_\(size)x\(size)@2x.png")
}

func writePNG(size: Int, name: String) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "MenuBarSpotifyIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not create icon bitmap."])
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    defer {
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
    }

    let canvas = NSRect(x: 0, y: 0, width: size, height: size)
    let inset = CGFloat(size) * 0.08
    let tile = canvas.insetBy(dx: inset, dy: inset)
    let radius = CGFloat(size) * 0.22

    NSColor(calibratedRed: 0.035, green: 0.035, blue: 0.04, alpha: 1).setFill()
    NSBezierPath(roundedRect: tile, xRadius: radius, yRadius: radius).fill()

    NSColor(calibratedWhite: 1, alpha: 0.18).setStroke()
    let border = NSBezierPath(roundedRect: tile.insetBy(dx: CGFloat(size) * 0.012, dy: CGFloat(size) * 0.012), xRadius: radius * 0.94, yRadius: radius * 0.94)
    border.lineWidth = max(1, CGFloat(size) * 0.012)
    border.stroke()

    NSColor(calibratedWhite: 0.94, alpha: 1).setFill()
    let stem = NSBezierPath(
        roundedRect: NSRect(
            x: CGFloat(size) * 0.49,
            y: CGFloat(size) * 0.30,
            width: CGFloat(size) * 0.085,
            height: CGFloat(size) * 0.46
        ),
        xRadius: CGFloat(size) * 0.04,
        yRadius: CGFloat(size) * 0.04
    )
    stem.fill()

    let noteHead = NSBezierPath(ovalIn: NSRect(
        x: CGFloat(size) * 0.25,
        y: CGFloat(size) * 0.21,
        width: CGFloat(size) * 0.32,
        height: CGFloat(size) * 0.17
    ))
    noteHead.fill()

    let flag = NSBezierPath()
    flag.move(to: NSPoint(x: CGFloat(size) * 0.53, y: CGFloat(size) * 0.76))
    flag.curve(
        to: NSPoint(x: CGFloat(size) * 0.78, y: CGFloat(size) * 0.67),
        controlPoint1: NSPoint(x: CGFloat(size) * 0.65, y: CGFloat(size) * 0.75),
        controlPoint2: NSPoint(x: CGFloat(size) * 0.76, y: CGFloat(size) * 0.74)
    )
    flag.curve(
        to: NSPoint(x: CGFloat(size) * 0.73, y: CGFloat(size) * 0.54),
        controlPoint1: NSPoint(x: CGFloat(size) * 0.82, y: CGFloat(size) * 0.63),
        controlPoint2: NSPoint(x: CGFloat(size) * 0.80, y: CGFloat(size) * 0.57)
    )
    flag.line(to: NSPoint(x: CGFloat(size) * 0.53, y: CGFloat(size) * 0.61))
    flag.close()
    flag.fill()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "MenuBarSpotifyIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not encode icon PNG."])
    }
    try png.write(to: iconset.appendingPathComponent(name))
}
