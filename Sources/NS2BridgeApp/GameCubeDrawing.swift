import NS2Kit
import SwiftUI

/// Stylized GameCube-style pad (original drawing, not Nintendo artwork), 520 × 340.
/// One solid silhouette (body + grips), big A with B and the X/Y kidneys around it, octagonal stick gates,
/// and L/R that fill with their analog travel.
struct GameCubeDrawing: View {
    let buttons: GCButtons
    let main: (x: Double, y: Double)
    let cStick: (x: Double, y: Double)
    let triggers: [Double]
    @Environment(\.colorScheme) private var scheme

    private var bodyFill: Color { scheme == .dark ? Color(white: 0.27) : Color(white: 0.87) }
    private var edge: Color { scheme == .dark ? Color(white: 0.45) : Color(white: 0.62) }
    private var idle: Color { scheme == .dark ? Color(white: 0.40) : Color(white: 0.74) }

    var body: some View {
        ZStack {
            // Shoulders
            trigger("L", .l, travel: triggers.first ?? 0, x: 125, y: 26)
            trigger("R", .r, travel: triggers.count > 1 ? triggers[1] : 0, x: 395, y: 26)
            shoulder("ZL", .zl, x: 180, y: 56)
            shoulder("Z", .z, x: 340, y: 56)

            silhouette

            // Left side
            gate(main, x: 145, y: 135, knob: idle.opacity(0.9), label: nil)
            dpad(x: 200, y: 205)

            // Center
            round("⌂", .home, x: 232, y: 108, w: 24, h: 24)
            round("◉", .capture, x: 288, y: 108, w: 24, h: 24)
            round("START", .start, x: 260, y: 145, w: 60, h: 22)
            round("C", .c, x: 260, y: 182, w: 24, h: 24)

            // Right side: A with B and the X / Y kidneys around it
            round("A", .a, x: 385, y: 138, w: 50, h: 50, font: 17)
            round("B", .b, x: 340, y: 158, w: 28, h: 28)
            kidney("X", .x, x: 427, y: 126, w: 22, h: 40, angle: -12)
            kidney("Y", .y, x: 378, y: 97, w: 40, h: 20, angle: -8)
            gate(cStick, x: 322, y: 208, knob: .gray, label: "C")
        }
        .frame(width: 520, height: 340)
        .animation(.easeOut(duration: 0.06), value: buttons.rawValue)
    }

    // MARK: Parts

    /// Body and grips drawn as one shape: all outlines first, then all fills, so no seams show.
    private var silhouette: some View {
        let body = RoundedRectangle(cornerRadius: 72, style: .continuous)
        let grip = RoundedRectangle(cornerRadius: 46, style: .continuous)
        return ZStack {
            Group {
                body.stroke(edge, lineWidth: 4).frame(width: 420, height: 176).position(x: 260, y: 152)
                grip.stroke(edge, lineWidth: 4).frame(width: 96, height: 128).rotationEffect(.degrees(12)).position(x: 150, y: 250)
                grip.stroke(edge, lineWidth: 4).frame(width: 96, height: 128).rotationEffect(.degrees(-12)).position(x: 370, y: 250)
            }
            Group {
                body.fill(bodyFill).frame(width: 420, height: 176).position(x: 260, y: 152)
                grip.fill(bodyFill).frame(width: 96, height: 128).rotationEffect(.degrees(12)).position(x: 150, y: 250)
                grip.fill(bodyFill).frame(width: 96, height: 128).rotationEffect(.degrees(-12)).position(x: 370, y: 250)
            }
        }
    }

    private func lit(_ b: GCButtons) -> Bool { buttons.contains(b) }

    private func trigger(_ t: String, _ b: GCButtons, travel: Double, x: CGFloat, y: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(idle.opacity(0.6))
            Capsule().fill(lit(b) ? Color.green : Color.accentColor)
                .frame(width: max(0, 110 * min(1, travel)))
            Text(lit(b) ? "\(t)  click" : "\(t)  \(Int((travel * 100).rounded()))%")
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .frame(width: 110)
                .foregroundStyle(travel > 0.5 || lit(b) ? .white : .primary)
        }
        .frame(width: 110, height: 24)
        .position(x: x, y: y)
    }

    private func shoulder(_ t: String, _ b: GCButtons, x: CGFloat, y: CGFloat) -> some View {
        Text(t).font(.system(size: 12, weight: .bold, design: .rounded))
            .frame(width: 58, height: 18)
            .background(Capsule().fill(lit(b) ? Color.accentColor : idle))
            .foregroundStyle(lit(b) ? .white : .primary)
            .position(x: x, y: y)
    }

    private func round(_ t: String, _ b: GCButtons, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                       color: Color? = nil, font: CGFloat = 11) -> some View {
        Text(t).font(.system(size: font, weight: .bold, design: .rounded))
            .frame(width: w, height: h)
            .background(Capsule().fill(lit(b) ? Color.accentColor : (color?.opacity(0.75) ?? idle)))
            .foregroundStyle(lit(b) || color != nil ? .white : .primary)
            .position(x: x, y: y)
    }

    private func kidney(_ t: String, _ b: GCButtons, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, angle: Double) -> some View {
        Text(t).font(.system(size: 11, weight: .bold, design: .rounded))
            .frame(width: w, height: h)
            .background(Capsule().fill(lit(b) ? Color.accentColor : idle))
            .foregroundStyle(lit(b) ? .white : .primary)
            .rotationEffect(.degrees(angle))
            .position(x: x, y: y)
    }

    /// Octagonal gate with the knob following the calibrated position.
    private func gate(_ v: (x: Double, y: Double), x: CGFloat, y: CGFloat, knob: Color, label: String?) -> some View {
        ZStack {
            Octagon().fill(Color.black.opacity(scheme == .dark ? 0.25 : 0.08)).frame(width: 66, height: 66)
            Octagon().stroke(edge, lineWidth: 1.5).frame(width: 66, height: 66)
            Circle().fill(knob).frame(width: 30, height: 30)
                .overlay(Circle().stroke(edge, lineWidth: 1))
                .overlay(Text(label ?? "").font(.system(size: 11, weight: .heavy, design: .rounded)).foregroundStyle(.black.opacity(0.7)))
                .offset(x: max(-1, min(1, v.x)) * 18, y: -max(-1, min(1, v.y)) * 18)
        }
        .position(x: x, y: y)
    }

    private func dpad(x: CGFloat, y: CGFloat) -> some View {
        let cells: [(GCButtons, CGFloat, CGFloat, String)] = [
            (.up, 0, -18, "▲"), (.down, 0, 18, "▼"), (.left, -18, 0, "◀"), (.right, 18, 0, "▶"),
        ]
        return ZStack {
            RoundedRectangle(cornerRadius: 3).fill(idle).frame(width: 18, height: 18)
            ForEach(cells, id: \.3) { c in
                Text(c.3).font(.system(size: 8))
                    .frame(width: 18, height: 18)
                    .background(RoundedRectangle(cornerRadius: 3).fill(lit(c.0) ? Color.accentColor : idle))
                    .foregroundStyle(lit(c.0) ? .white : .primary)
                    .offset(x: c.1, y: c.2)
            }
        }
        .position(x: x, y: y)
    }
}

/// Regular octagon, flat on top (the GameCube's notched gate).
struct Octagon: Shape {
    func path(in r: CGRect) -> Path {
        let c = CGPoint(x: r.midX, y: r.midY), rad = min(r.width, r.height) / 2
        var p = Path()
        for i in 0..<8 {
            let a = Double(i) * .pi / 4 + .pi / 8
            let pt = CGPoint(x: c.x + rad * cos(a), y: c.y + rad * sin(a))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        return p
    }
}
