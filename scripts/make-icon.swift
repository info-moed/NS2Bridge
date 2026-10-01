// Renders Resources/AppIcon.icns: a generic gamepad with "NS2P".
// Original artwork drawn in code — deliberately NOT Nintendo's controller design or logos.
// Usage: swift scripts/make-icon.swift
import AppKit

func draw(size s: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: s, height: s))
    img.lockFocus()
    let k = s / 1024

    // macOS-style rounded square with a deep blue→violet gradient
    let bg = NSBezierPath(roundedRect: NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k),
                          xRadius: 185 * k, yRadius: 185 * k)
    NSGradient(colors: [NSColor(calibratedRed: 0.11, green: 0.14, blue: 0.32, alpha: 1),
                        NSColor(calibratedRed: 0.36, green: 0.16, blue: 0.55, alpha: 1)])!
        .draw(in: bg, angle: -60)

    // Gamepad silhouette: body + two grips
    let pad = NSColor(calibratedWhite: 0.97, alpha: 1)
    pad.setFill()
    let body = NSBezierPath(roundedRect: NSRect(x: 230 * k, y: 480 * k, width: 564 * k, height: 230 * k),
                            xRadius: 115 * k, yRadius: 115 * k)
    body.fill()
    for x in [230.0, 614.0] {
        let grip = NSBezierPath(ovalIn: NSRect(x: x * k, y: 380 * k, width: 180 * k, height: 250 * k))
        grip.fill()
    }

    // Controls in the background color
    let ink = NSColor(calibratedRed: 0.20, green: 0.16, blue: 0.42, alpha: 1)
    ink.setFill()
    // D-pad
    NSBezierPath(roundedRect: NSRect(x: 290 * k, y: 580 * k, width: 110 * k, height: 36 * k), xRadius: 8 * k, yRadius: 8 * k).fill()
    NSBezierPath(roundedRect: NSRect(x: 327 * k, y: 543 * k, width: 36 * k, height: 110 * k), xRadius: 8 * k, yRadius: 8 * k).fill()
    // Face buttons (diamond)
    for (x, y) in [(680.0, 640.0), (720.0, 598.0), (680.0, 556.0), (640.0, 598.0)] {
        NSBezierPath(ovalIn: NSRect(x: (x - 20) * k, y: (y - 20) * k, width: 40 * k, height: 40 * k)).fill()
    }
    // Sticks
    for x in [430.0, 594.0] {
        NSBezierPath(ovalIn: NSRect(x: (x - 38) * k, y: (515 - 38) * k, width: 76 * k, height: 76 * k)).fill()
    }

    // "NS2P"
    let font = NSFont.systemFont(ofSize: 190 * k, weight: .heavy)
    let text = NSAttributedString(string: "NS2P", attributes: [
        .font: font,
        .foregroundColor: NSColor.white,
        .kern: 6 * k,
    ])
    let ts = text.size()
    text.draw(at: NSPoint(x: (1024 * k - ts.width) / 2, y: 150 * k))

    img.unlockFocus()
    return img
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = CGFloat(base * scale)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw(size: px).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}

let out = root.appendingPathComponent("Resources/AppIcon.icns")
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", out.path]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "wrote \(out.path)" : "iconutil failed")
