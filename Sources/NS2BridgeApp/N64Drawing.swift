import NS2Kit
import SwiftUI

/// Stylized N64-style pad (original drawing, not Nintendo artwork).
struct N64Drawing: View {
    let buttons: N64Buttons
    let stick: (x: Double, y: Double)

    var body: some View {
        ZStack {
            shoulder("L", .l, x: 110, y: 22)
            shoulder("R", .r, x: 410, y: 22)
            shoulder("ZR", .zr, x: 340, y: 22)
            Capsule().fill(.quaternary).overlay(Capsule().stroke(.tertiary, lineWidth: 2))
                .frame(width: 440, height: 170).position(x: 260, y: 120)
            RoundedRectangle(cornerRadius: 44).fill(.quaternary).overlay(RoundedRectangle(cornerRadius: 44).stroke(.tertiary, lineWidth: 2))
                .frame(width: 112, height: 190).position(x: 260, y: 235)

            dpad(x: 120, y: 120)
            round("START", .start, x: 260, y: 95, w: 56, h: 26, color: .red)
            round("◉", .capture, x: 232, y: 60, w: 26, h: 26)
            round("⌂", .home, x: 288, y: 60, w: 26, h: 26)

            // Stick
            ZStack {
                Circle().fill(Color.gray.opacity(0.2)).frame(width: 64, height: 64)
                Circle().stroke(Color.gray.opacity(0.5)).frame(width: 64, height: 64)
                Circle().fill(Color.primary.opacity(0.75)).frame(width: 26, height: 26)
                    .offset(x: stick.x * 20, y: -stick.y * 20)
            }
            .position(x: 260, y: 215)
            round("Z", .z, x: 260, y: 300, w: 44, h: 26)

            // A / B
            round("B", .b, x: 360, y: 150, w: 32, h: 32, color: .green)
            round("A", .a, x: 392, y: 172, w: 36, h: 36, color: .blue)
            // C cluster
            round("▲", .cUp, x: 410, y: 88, w: 26, h: 26, color: .yellow)
            round("▼", .cDown, x: 410, y: 136, w: 26, h: 26, color: .yellow)
            round("◀", .cLeft, x: 386, y: 112, w: 26, h: 26, color: .yellow)
            round("▶", .cRight, x: 434, y: 112, w: 26, h: 26, color: .yellow)
        }
        .animation(.easeOut(duration: 0.06), value: buttons.rawValue)
    }

    private func lit(_ b: N64Buttons) -> Bool { buttons.contains(b) }

    private func shoulder(_ t: String, _ b: N64Buttons, x: CGFloat, y: CGFloat) -> some View {
        Text(t).font(.system(size: 13, weight: .bold))
            .frame(width: 64, height: 24)
            .background(RoundedRectangle(cornerRadius: 8).fill(lit(b) ? Color.accentColor : Color.gray.opacity(0.25)))
            .foregroundStyle(lit(b) ? .white : .primary)
            .position(x: x, y: y)
    }

    private func round(_ t: String, _ b: N64Buttons, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat, color: Color = .gray) -> some View {
        Text(t).font(.system(size: 11, weight: .bold))
            .frame(width: w, height: h)
            .background(Capsule().fill(lit(b) ? Color.accentColor : color.opacity(0.35)))
            .foregroundStyle(lit(b) ? .white : .primary)
            .position(x: x, y: y)
    }

    private func dpad(x: CGFloat, y: CGFloat) -> some View {
        let cells: [(N64Buttons, CGFloat, CGFloat, String)] = [
            (.up, 0, -22, "▲"), (.down, 0, 22, "▼"), (.left, -22, 0, "◀"), (.right, 22, 0, "▶"),
        ]
        return ZStack {
            ForEach(cells, id: \.3) { c in
                Text(c.3).font(.system(size: 10))
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 4).fill(lit(c.0) ? Color.accentColor : Color.gray.opacity(0.35)))
                    .foregroundStyle(lit(c.0) ? .white : .primary)
                    .offset(x: c.1, y: c.2)
            }
        }
        .position(x: x, y: y)
    }
}
