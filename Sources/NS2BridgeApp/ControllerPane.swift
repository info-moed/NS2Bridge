import NS2Kit
import SwiftUI

/// Live drawing of the selected controller: pressed buttons light up, stick dots follow calibrated input.
struct ControllerPane: View {
    @Environment(BridgeModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Live view").font(.title2.bold())
            Text("Press buttons and move the sticks: everything \(model.selected.map { "P\($0.player)'s \($0.kind.displayName)" } ?? "the controller") sends shows up here instantly.")
                .foregroundStyle(.secondary)
            Group {
                switch model.selectedKind {
                case .switch2Pro:
                    ControllerDrawing(
                        buttons: model.proState?.buttons ?? [],
                        left: model.proState.map { model.calibration(0).apply($0.left) } ?? (x: 0, y: 0),
                        right: model.proState.map { model.calibration(1).apply($0.right) } ?? (x: 0, y: 0)
                    )
                    .frame(width: 560, height: 340)
                case .n64:
                    N64Drawing(buttons: model.n64State?.buttons ?? [],
                               stick: model.n64State.map { model.calibrated(0, $0.stick) } ?? (x: 0, y: 0))
                    .frame(width: 520, height: 340)
                case .gameCube:
                    GameCubeDrawing(buttons: model.gcState?.buttons ?? [],
                                    main: model.gcState.map { model.calibrated(0, $0.main) } ?? (x: 0, y: 0),
                                    cStick: model.gcState.map { model.calibrated(1, $0.cStick) } ?? (x: 0, y: 0),
                                    triggers: model.input?.triggers ?? [])
                    .frame(width: 520, height: 340)
                }
            }
            .opacity(model.isConnected ? 1 : 0.35)
            .frame(maxWidth: .infinity)

            if let i = model.input, model.isConnected {
                HStack(spacing: 24) {
                    ForEach(Array(i.sticks.enumerated()), id: \.offset) { n, stick in
                        StickReadout(title: model.selectedKind.stickNames[n], raw: stick, cal: model.calibrated(n, stick))
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Profile").font(.headline)
                        Text(model.profile.name).font(.caption)
                    }
                }
            }
        }
    }
}

struct StickReadout: View {
    let title: String
    let raw: Stick
    let cal: (x: Double, y: Double)
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text("raw \(raw.x), \(raw.y)").font(.caption.monospaced()).foregroundStyle(.secondary)
            Text(String(format: "calibrated %+.2f, %+.2f", cal.x, cal.y)).font(.caption.monospaced())
        }
    }
}

struct ControllerDrawing: View {
    let buttons: ProButtons
    let left: (x: Double, y: Double)
    let right: (x: Double, y: Double)

    var body: some View {
        ZStack {
            // Shoulders / triggers
            shoulder("ZL", .zl, x: 120, y: 18)
            shoulder("L", .l, x: 150, y: 46)
            shoulder("R", .r, x: 410, y: 46)
            shoulder("ZR", .zr, x: 440, y: 18)

            // Body
            RoundedRectangle(cornerRadius: 110, style: .continuous)
                .fill(.quaternary)
                .overlay(RoundedRectangle(cornerRadius: 110, style: .continuous).stroke(.tertiary, lineWidth: 2))
                .frame(width: 480, height: 230)
                .position(x: 280, y: 170)

            // Center buttons
            small("−", .minus, x: 235, y: 100)
            small("+", .plus, x: 325, y: 100)
            small("◉", .capture, x: 235, y: 140, square: true)
            small("⌂", .home, x: 325, y: 140)
            small("C", .c, x: 325, y: 178)

            // Sticks
            stick(left, pressed: buttons.contains(.leftStick), label: "L", x: 165, y: 130)
            stick(right, pressed: buttons.contains(.rightStick), label: "R", x: 370, y: 215)

            // D-pad
            dpad(x: 200, y: 215)

            // Face buttons
            face("X", .x, x: 420, y: 100)
            face("A", .a, x: 452, y: 132)
            face("B", .b, x: 420, y: 164)
            face("Y", .y, x: 388, y: 132)

            // Back paddles
            paddle("GL · back", .gl, x: 190, y: 312)
            paddle("GR · back", .gr, x: 370, y: 312)
        }
        .animation(.easeOut(duration: 0.06), value: buttons.rawValue)
    }

    private func lit(_ b: ProButtons) -> Bool { buttons.contains(b) }

    private func shoulder(_ t: String, _ b: ProButtons, x: CGFloat, y: CGFloat) -> some View {
        Text(t).font(.system(size: 13, weight: .bold))
            .frame(width: 70, height: 24)
            .background(RoundedRectangle(cornerRadius: 8).fill(lit(b) ? Color.accentColor : Color.gray.opacity(0.25)))
            .foregroundStyle(lit(b) ? .white : .primary)
            .position(x: x, y: y)
    }

    private func face(_ t: String, _ b: ProButtons, x: CGFloat, y: CGFloat) -> some View {
        Text(t).font(.system(size: 14, weight: .bold))
            .frame(width: 30, height: 30)
            .background(Circle().fill(lit(b) ? Color.accentColor : Color.gray.opacity(0.35)))
            .foregroundStyle(lit(b) ? .white : .primary)
            .position(x: x, y: y)
    }

    private func small(_ t: String, _ b: ProButtons, x: CGFloat, y: CGFloat, square: Bool = false) -> some View {
        Text(t).font(.system(size: 12, weight: .bold))
            .frame(width: 24, height: 24)
            .background(
                Group {
                    if square { RoundedRectangle(cornerRadius: 5).fill(lit(b) ? Color.accentColor : Color.gray.opacity(0.35)) }
                    else { Circle().fill(lit(b) ? Color.accentColor : Color.gray.opacity(0.35)) }
                }
            )
            .foregroundStyle(lit(b) ? .white : .primary)
            .position(x: x, y: y)
    }

    private func paddle(_ t: String, _ b: ProButtons, x: CGFloat, y: CGFloat) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold))
            .frame(width: 100, height: 22)
            .background(Capsule().fill(lit(b) ? Color.accentColor : Color.gray.opacity(0.25)))
            .foregroundStyle(lit(b) ? .white : .secondary)
            .position(x: x, y: y)
    }

    private func stick(_ v: (x: Double, y: Double), pressed: Bool, label: String, x: CGFloat, y: CGFloat) -> some View {
        ZStack {
            Circle().fill(Color.gray.opacity(0.2)).frame(width: 64, height: 64)
            Circle().stroke(Color.gray.opacity(0.5), lineWidth: 1).frame(width: 64, height: 64)
            Circle()
                .fill(pressed ? Color.accentColor : Color.primary.opacity(0.75))
                .frame(width: 26, height: 26)
                .offset(x: v.x * 20, y: -v.y * 20)
        }
        .position(x: x, y: y)
    }

    private func dpad(x: CGFloat, y: CGFloat) -> some View {
        let cells: [(ProButtons, CGFloat, CGFloat, String)] = [
            (.dpadUp, 0, -22, "▲"), (.dpadDown, 0, 22, "▼"), (.dpadLeft, -22, 0, "◀"), (.dpadRight, 22, 0, "▶"),
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
