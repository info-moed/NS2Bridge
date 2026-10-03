import AppKit
import ImageIO
import SwiftUI

/// The startup animation: a voxel (3D pixel-art) generic gamepad assembles from flying blocks while it spins
/// into view, the title drops in letter by letter, then everything zooms through into the app. About 2.7 s; a click
/// or any key skips it. Not shown with Reduce Motion, during the screenshot tour, or when turned off in Setup.
struct IntroAnimation: View {
    let onFinish: () -> Void
    @State private var start = Date()
    @State private var skipAt: Date?

    static let duration = 2.9

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSince(start)
            let exit = skipAt.map { timeline.date.timeIntervalSince($0) / 0.25 } ?? max(0, (t - 2.45) / 0.45)
            Canvas { ctx, size in
                IntroRenderer.draw(&ctx, size: size, t: t, exit: min(1, exit))
            }
            .opacity(1 - min(1, exit))
            .onChange(of: exit >= 1) { _, done in if done { onFinish() } }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture { skip() }
        .background(KeyCatcher(onKey: skip))
        .accessibilityLabel("NS2 Bridge")
        .accessibilityHint("Startup animation. Click to skip.")
        .onAppear { start = Date() }
    }

    private func skip() { if skipAt == nil { skipAt = Date() } }
}

/// Skips the intro on any key press.
private struct KeyCatcher: NSViewRepresentable {
    let onKey: () -> Void
    func makeNSView(context: Context) -> NSView {
        let v = KeyView(); v.onKey = onKey
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    final class KeyView: NSView {
        var onKey: (() -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) { onKey?() }
    }
}

// MARK: - Rendering

/// One frame of the intro (for `--render-intro`: frames and an animated GIF for the documentation).
struct IntroFrame: View {
    let t: Double
    var body: some View {
        Canvas { ctx, size in IntroRenderer.draw(&ctx, size: size, t: t, exit: max(0, min(1, (t - 2.45) / 0.45))) }
    }
}

enum IntroRenderer {
    struct Voxel {
        var x: Double, y: Double, z: Double       // model position, in voxels, centered
        var color: SIMD3<Double>                  // RGB 0…1
        var scatter: SIMD3<Double>                // where it flies in from
        var delay: Double
        var title: Bool
    }

    // The controller, 32 × 18 pixels, from simple shapes (top view).
    static let controller: [(Int, Int, SIMD3<Double>)] = {
        var px: [(Int, Int, SIMD3<Double>)] = []
        let body = SIMD3(0.36, 0.38, 0.43), top = SIMD3(0.50, 0.53, 0.60), edge = SIMD3(0.22, 0.23, 0.27)
        func inBody(_ x: Double, _ y: Double) -> Bool {
            let rect = x >= 3 && x <= 28 && y >= 3 && y <= 11
            let rounded = rect && !((x < 5 || x > 26) && (y < 5) && hypot(x - (x < 5 ? 5 : 26), y - 5) > 2.2)
            let grips = hypot(x - 7.5, y - 12.5) <= 4.6 || hypot(x - 23.5, y - 12.5) <= 4.6
            return rounded || grips
        }
        for y in 0..<18 {
            for x in 0..<32 {
                let fx = Double(x), fy = Double(y)
                if (y == 1 || y == 2), (4...10).contains(x) || (21...27).contains(x) {
                    px.append((x, y, y == 1 ? edge : SIMD3(0.30, 0.31, 0.36)))            // shoulders
                    continue
                }
                guard inBody(fx, fy) else { continue }
                var c = fy <= 4 ? top : body
                let onEdge = !inBody(fx - 1, fy) || !inBody(fx + 1, fy) || !inBody(fx, fy + 1)
                if onEdge { c = edge }
                func near(_ cx: Double, _ cy: Double, _ r: Double) -> Bool { hypot(fx - cx, fy - cy) <= r }
                if near(9, 7, 2.3) { c = near(9, 7, 0.9) ? SIMD3(0.75, 0.78, 0.85) : SIMD3(0.10, 0.11, 0.13) }   // left stick
                if near(20, 10, 2.3) { c = near(20, 10, 0.9) ? SIMD3(0.75, 0.78, 0.85) : SIMD3(0.10, 0.11, 0.13) } // right stick
                if (x == 13 && (10...14).contains(y)) || (y == 12 && (11...15).contains(x)) { c = SIMD3(0.12, 0.13, 0.15) } // d-pad
                // A generic gamepad: four gray face buttons in a diamond, two small center buttons, one
                // light accent. No product's colors or product-specific buttons (LEGAL.md §1).
                if (x == 24 && (y == 5 || y == 9)) || (y == 7 && (x == 22 || x == 26)) { c = SIMD3(0.80, 0.82, 0.86) }
                if (x == 14 || x == 17) && y == 6 { c = SIMD3(0.62, 0.65, 0.71) }
                if x == 15 && y == 9 || x == 16 && y == 9 { c = SIMD3(0.30, 0.85, 0.95) }   // cyan accent light
                px.append((x, y, c))
            }
        }
        return px
    }()

    // A 5 × 7 pixel font for the title.
    static let glyphs: [Character: [String]] = [
        "N": ["#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#"],
        "S": [".####", "#....", "#....", ".###.", "....#", "....#", "####."],
        "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
        "B": ["####.", "#...#", "#...#", "####.", "#...#", "#...#", "####."],
        "R": ["####.", "#...#", "#...#", "####.", "#.#..", "#..#.", "#...#"],
        "I": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "#####"],
        "D": ["####.", "#...#", "#...#", "#...#", "#...#", "#...#", "####."],
        "G": [".####", "#....", "#....", "#.###", "#...#", "#...#", ".###."],
        "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
    ]

    static let voxels: [Voxel] = {
        var rng = SplitMix(seed: 2069)
        var out: [Voxel] = []
        let depth = 3
        for (x, y, c) in controller {
            for z in 0..<depth {
                let dir = SIMD3(rng.next() * 2 - 1, rng.next() * 2 - 1, rng.next() * 2 - 1)
                let n = dir / max(0.001, (dir * dir).sum().squareRoot())
                out.append(Voxel(x: Double(x) - 15.5, y: Double(y) - 9.5, z: Double(z) - 1,
                                 color: c * (1 - 0.18 * Double(z)), scatter: n * (40 + 30 * rng.next()),
                                 delay: 0.05 + 0.35 * (Double(x) / 31) + 0.12 * rng.next(), title: false))
            }
        }
        // Title "NS2 BRIDGE", centered on its own origin (drawn with its own, steadier camera below the controller).
        let title = Array("NS2 BRIDGE")
        let scale = 0.55, letterW = 6.0 * scale
        let startX = -Double(title.count) * letterW / 2
        for (i, ch) in title.enumerated() {
            guard let g = glyphs[ch] else { continue }
            for (gy, row) in g.enumerated() {
                for (gx, cell) in row.enumerated() where cell == "#" {
                    let grad = Double(gy) / 6
                    let color = SIMD3(0.55 + 0.45 * (1 - grad), 0.95 - 0.25 * grad, 1.0)        // white → cyan
                    for z in 0..<2 {
                        out.append(Voxel(x: startX + Double(i) * letterW + Double(gx) * scale,
                                         y: (Double(gy) - 3) * scale, z: Double(z) * scale - 0.3,
                                         color: color * (1 - 0.3 * Double(z)), scatter: SIMD3(0, -30 - 10 * rng.next(), 0),
                                         delay: 0.8 + 0.05 * Double(i), title: true))
                    }
                }
            }
        }
        return out
    }()

    static let stars: [(Double, Double, Double)] = {
        var rng = SplitMix(seed: 64)
        return (0..<90).map { _ in (rng.next(), rng.next(), rng.next()) }
    }()

    static func easeOutBack(_ x: Double) -> Double {
        let c1 = 1.4, c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, t: Double, exit: Double) {
        // Background: deep space gradient, twinkling pixel stars, vignette.
        let rect = CGRect(origin: .zero, size: size)
        ctx.fill(Path(rect), with: .radialGradient(Gradient(colors: [Color(red: 0.07, green: 0.09, blue: 0.20), .black]),
                                                  center: CGPoint(x: size.width / 2, y: size.height * 0.42),
                                                  startRadius: 0, endRadius: max(size.width, size.height) * 0.75))
        for (sx, sy, phase) in stars {
            let tw = 0.35 + 0.65 * abs(sin(t * 2.2 + phase * 10))
            let s: CGFloat = phase > 0.8 ? 3 : 2
            ctx.fill(Path(CGRect(x: sx * size.width, y: sy * size.height, width: s, height: s)),
                     with: .color(.white.opacity(0.5 * tw)))
        }

        // Camera: spin into a three-quarter view, then a slow idle sway; zoom through on exit.
        let settle = min(1, max(0, t / 1.3))
        let spin = (1 - easeOutBack(settle)) * .pi * 2.2
        let yaw = -0.42 + spin + 0.06 * sin(t * 1.7)
        let pitch = 0.42 - 0.12 * settle + 0.04 * sin(t * 1.3)
        let zoom = 1 + 1.6 * exit * exit
        let unit = min(size.width / 46, size.height / 34) * zoom
        let center = CGPoint(x: size.width / 2, y: size.height * 0.40)
        let titleCenter = CGPoint(x: size.width / 2, y: center.y + unit * 14.2)
        // The title keeps a steady, nearly front-facing view.
        let titleYaw = 0.12 * sin(t * 1.1), titlePitch = 0.18
        let cam = (cos(yaw), sin(yaw), cos(pitch), sin(pitch))
        let titleCam = (cos(titleYaw), sin(titleYaw), cos(titlePitch), sin(titlePitch))

        struct Quad { var z: Double; var rect: CGRect; var color: Color }
        var quads: [Quad] = []
        quads.reserveCapacity(voxels.count)
        for v in voxels {
            let p = min(1, max(0, (t - v.delay) / (v.title ? 0.5 : 0.75)))
            guard p > 0 else { continue }
            let e = easeOutBack(p)
            var x = v.x + v.scatter.x * (1 - e), y = v.y + v.scatter.y * (1 - e), z = v.z + v.scatter.z * (1 - e)
            let (cy, sy, cp, sp) = v.title ? titleCam : cam
            let origin = v.title ? titleCenter : center
            let x1 = x * cy + z * sy, z1 = -x * sy + z * cy
            let y2 = y * cp - z1 * sp, z2 = y * sp + z1 * cp
            let persp = 150 / (150 + z2)                           // gentle perspective
            let s = unit * persp
            let sx = origin.x + x1 * s, syy = origin.y + y2 * s
            // Light sweep: a bright band crossing the controller once it's assembled.
            let sweep = max(0, 1 - abs((x1 + 18) - (t - 1.2) * 40) / 3) * (v.title ? 0.4 : 1)
            let shade = 0.82 + 0.18 * persp + 0.5 * sweep
            let c = v.color * shade
            quads.append(Quad(z: z2, rect: CGRect(x: sx - s / 2, y: syy - s / 2, width: s * 1.04, height: s * 1.04),
                              color: Color(red: c.x, green: c.y, blue: c.z).opacity(min(1, p * 3))))
        }
        quads.sort { $0.z > $1.z }                                // far first (painter's order)
        for q in quads { ctx.fill(Path(q.rect), with: .color(q.color)) }

        // Glow under the controller once assembled.
        let glow = min(1, max(0, (t - 0.9) / 0.6))
        if glow > 0 {
            let r = unit * 18
            ctx.fill(Path(ellipseIn: CGRect(x: center.x - r, y: center.y + unit * 9.5, width: r * 2, height: unit * 3)),
                     with: .radialGradient(Gradient(colors: [Color.cyan.opacity(0.25 * glow), .clear]),
                                           center: CGPoint(x: center.x, y: center.y + unit * 11), startRadius: 0, endRadius: r))
        }

        // Subtitle.
        let sub = min(1, max(0, (t - 1.4) / 0.4))
        if sub > 0 {
            let text = Text("GAME CONTROLLERS ON YOUR MAC · RUMBLE · GYRO · BLUETOOTH")
                .font(.system(size: max(10, unit * 0.9), weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.75 * sub * (1 - exit)))
            ctx.draw(text, at: CGPoint(x: center.x, y: titleCenter.y + unit * 4.6))
        }

        // CRT scanlines.
        var y: CGFloat = 0
        while y < size.height {
            ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(.black.opacity(0.18)))
            y += 3
        }
    }
}

/// A tiny deterministic random generator, so the animation is the same every launch.
private struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}

/// `NS2Bridge --render-intro <folder>`: the intro as PNG frames and a looping animated GIF (for the documentation).
@MainActor
enum IntroExporter {
    static func render(to folder: URL, width: CGFloat = 720, height: CGFloat = 420, fps: Double = 24) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Up to the finished title (no exit fade), whose last frame holds for 2 s before the GIF loops.
        let count = Int(2.45 * fps)
        let gifURL = folder.appendingPathComponent("intro.gif") as CFURL
        guard let gif = CGImageDestinationCreateWithURL(gifURL, "com.compuserve.gif" as CFString, count, nil) else { return }
        CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for i in 0..<count {
            let delay = i == count - 1 ? 2.0 : 1 / fps
            let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary
            let t = Double(i) / fps
            let renderer = ImageRenderer(content: IntroFrame(t: t).frame(width: width, height: height))
            renderer.scale = 1
            guard let image = renderer.cgImage else { continue }
            CGImageDestinationAddImage(gif, image, frameProps)
            if i % 10 == 0 {
                let rep = NSBitmapImageRep(cgImage: image)
                try? rep.representation(using: .png, properties: [:])?.write(to: folder.appendingPathComponent(String(format: "intro-%03d.png", i)))
            }
        }
        CGImageDestinationFinalize(gif)
    }

    /// The finished title frame at 1280 × 640: GitHub's social-preview size.
    static func renderSocialPreview(to file: URL) {
        let renderer = ImageRenderer(content: IntroFrame(t: 2.4).frame(width: 1280, height: 640))
        renderer.scale = 1
        guard let image = renderer.cgImage else { return }
        try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file)
    }
}
