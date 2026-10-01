import Foundation
import IOKit.hid
import GameController
import NS2Kit

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
ns2probe — Switch 2 controller probe (Phase 0)

  ns2probe info                          USB descriptor dump (interfaces + endpoints)
  ns2probe init [--led N] [--minimal] [--keep S]
                                         send the 0x91 init over interface 1, print replies
                                         --minimal: skip UNKNOWN_07/16   --keep S: hold iface open S seconds
  ns2probe stream [--seconds N] [--init] [--out file.ns2cap] [--quiet]
                                         read raw HID reports (interface 0), byte stats at end
  ns2probe gc [--seconds N] [--init]     what GameController.framework sees
  ns2probe rumble [preset] [--seconds N] preset: gentle|medium|strong|fade (default medium)
  ns2probe spi <hexaddr> [len]           EXPERIMENTAL SPI flash read over interface 1
"""

var args = Array(CommandLine.arguments.dropFirst())
func flag(_ name: String) -> Bool {
    if let i = args.firstIndex(of: name) { args.remove(at: i); return true }
    return false
}
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
}
func fail(_ msg: String) -> Never { print("✗ \(msg)"); exit(1) }

func productID() -> Int {
    guard let pid = VendorUSB.attachedProductID() else {
        fail("no Switch 2-family controller on USB (need 057E:2066/2067/2069/2073, data cable)")
    }
    return pid
}

func runLoop(seconds: Double, tick: Double = 0.25, _ onTick: () -> Void = {}) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        CFRunLoopRunInMode(.defaultMode, tick, false)
        onTick()
    }
}

@discardableResult
func sendInit(led: UInt8, minimal: Bool, verbose: Bool = true) -> VendorUSB? {
    let pid = productID()
    let usb: VendorUSB
    do { usb = try VendorUSB(productID: pid) } catch { print("✗ \(error)"); return nil }
    if verbose { print(String(format: "→ %@ (057E:%04X): interface 1 claimed", NS2Device.names[pid] ?? "?", pid)) }
    // Each controller's own report format (0x09 Pro, 0x0A GameCube), not always the Pro's.
    let format = ControllerKind(productID: pid)?.nativeReportFormat ?? ControllerState.reportID
    for step in NS2Command.initSequence(includeUnknown: !minimal, led: led, format: format) {
        do {
            let reply = try usb.command(step.bytes)
            if verbose {
                print("  \(step.name.padding(toLength: 16, withPad: " ", startingAt: 0)) → \(step.bytes.hex)")
                print("  \("".padding(toLength: 16, withPad: " ", startingAt: 0)) ← \(reply.map { $0.hex } ?? "(no reply)")")
            }
        } catch {
            print("  \(step.name): ✗ \(error)")
        }
        usleep(20_000)
    }
    return usb
}

let cmd = args.isEmpty ? "help" : args.removeFirst()

switch cmd {
case "info":
    let pid = productID()
    do {
        let usb = try VendorUSB(productID: pid)
        print(String(format: "%@  057E:%04X", NS2Device.names[pid] ?? "?", pid))
        print(usb.config.description)
        usb.close()
    } catch { fail("\(error)") }
    print("Input Monitoring (this process): \(HIDLink.accessStatus)")

case "init":
    let led = UInt8(option("--led").flatMap { Int($0) } ?? 1)
    let keep = Double(option("--keep") ?? "0") ?? 0
    guard let usb = sendInit(led: led, minimal: flag("--minimal")) else { exit(1) }
    if keep > 0 { print("holding interface open \(keep)s…"); runLoop(seconds: keep) }
    usb.close()
    print("✓ done — the player LED should now show pattern \(led)")

case "stream":
    let seconds = Double(option("--seconds") ?? "10") ?? 10
    let out = option("--out")
    let quiet = flag("--quiet")
    var usb: VendorUSB?
    if flag("--init") { usb = sendInit(led: 1, minimal: false, verbose: false); print("→ init sent") }

    let link = HIDLink()
    let writer = try out.map { try CaptureWriter(url: URL(fileURLWithPath: $0)) }
    var stats: [UInt8: ByteStats] = [:]
    var perID: [UInt8: Int] = [:]
    var lastSecond: [UInt8: Int] = [:]
    var latest: [UInt8] = []
    var total = 0
    var lastLen = 0
    link.onDevice = { up, pid in print(String(format: "%@ HID device 057E:%04X", up ? "+" : "-", pid)) }
    link.onReport = { r, _ in
        guard let id = r.first else { return }
        total += 1; perID[id, default: 0] += 1; lastSecond[id, default: 0] += 1
        stats[id, default: ByteStats()].add(r)
        latest = r; lastLen = r.count
        writer?.append(r)
    }
    do { try link.start() } catch { fail("\(error)") }
    print("reading for \(seconds)s — move sticks / press buttons / rotate the controller…")
    var ticks = 0
    runLoop(seconds: seconds, tick: 0.25) {
        ticks += 1
        if !quiet, !latest.isEmpty { print(latest.hex) }
        if ticks % 4 == 0 {
            let rates = lastSecond.sorted { $0.key < $1.key }.map { String(format: "0x%02X:%dHz", $0.key, $0.value) }
            print("  [rate] \(rates.isEmpty ? "no reports" : rates.joined(separator: " "))")
            lastSecond.removeAll()
        }
    }
    link.stop(); usb?.close(); writer?.close()
    print("\n=== \(total) reports, len \(lastLen) ===")
    for (id, n) in perID.sorted(by: { $0.key < $1.key }) {
        print(String(format: "report 0x%02X: %d", id, n))
        print(stats[id]!.report(length: 64))
    }
    if let out, let writer { print("saved \(writer.count) reports → \(out)") }
    if total == 0 { print("⚠ no input reports. Try: ns2probe stream --init   (Input Monitoring: \(HIDLink.accessStatus))") }

case "guided":
    // Prompts the user through labeled segments; writes <out>.ns2cap + <out>.labels (ms<TAB>label).
    let base = option("--out") ?? (NSHomeDirectory() + "/Desktop/ns2-guided")
    let usb = sendInit(led: 1, minimal: false, verbose: false)
    let link = HIDLink()
    let writer = try CaptureWriter(url: URL(fileURLWithPath: base + ".ns2cap"))
    var labels = ""
    let t0 = DispatchTime.now().uptimeNanoseconds
    func nowMs() -> UInt64 { (DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000 }
    link.onReport = { r, _ in writer.append(r) }
    do { try link.start() } catch { fail("\(error)") }
    let buttons = ["A", "B", "X", "Y", "L", "R", "ZL", "ZR", "MINUS (-)", "PLUS (+)",
                   "LEFT STICK CLICK", "RIGHT STICK CLICK", "HOME", "CAPTURE", "C (new button)",
                   "GL (back-left paddle)", "GR (back-right paddle)",
                   "D-PAD UP", "D-PAD DOWN", "D-PAD LEFT", "D-PAD RIGHT"]
    var steps: [(String, Double)] = [
        ("still: lay the controller FLAT on the desk, hands off", 4),
        ("pitch: tilt the top edge up/down repeatedly (like nodding)", 5),
        ("still", 2),
        ("roll: tilt left grip down / right grip down repeatedly", 5),
        ("still", 2),
        ("yaw: flat on desk, twist it left/right (like a steering wheel lying flat)", 5),
        ("still", 2),
        ("left stick: full circles", 4),
        ("right stick: full circles", 4),
    ]
    for b in buttons { steps.append(("press and hold: \(b)", 2.5)); steps.append(("release everything", 1)) }
    steps.append(("done", 0.5))
    print("Guided capture — \(steps.count) steps, about \(Int(steps.map(\.1).reduce(0, +)))s. Follow the prompts.")
    runLoop(seconds: 1)
    for (i, (label, secs)) in steps.enumerated() {
        print(String(format: "[%2d/%d] %@", i + 1, steps.count, label))
        labels += "\(nowMs())\t\(label)\n"
        runLoop(seconds: secs, tick: 0.05)
    }
    labels += "\(nowMs())\tEND\n"
    link.stop(); usb?.close(); writer.close()
    try labels.write(toFile: base + ".labels", atomically: true, encoding: .utf8)
    print("✓ saved \(writer.count) reports → \(base).ns2cap (+ .labels)")

case "buttons":
    // User-paced wizard: waits for each button to be HELD, then released. Motion steps last (press A to start/stop).
    // Every press is checked against the bit NS2 Bridge expects for that button; a press that disagrees has
    // to be confirmed by pressing it again, so a slip (e.g. Capture pressed when asked for C) can't silently
    // end up in the data. Works with the Switch 2 Pro (report 0x09) and the NSO GameCube (0x0A).
    let pid = productID()
    let isGameCube = pid == NS2Device.gameCubeNSO
    let reportID: UInt8 = isGameCube ? GameCubeReport.inputID : ControllerState.reportID
    let skipMotion = flag("--no-motion") || isGameCube
    let base = option("--out") ?? (NSHomeDirectory() + "/Desktop/" + (isGameCube ? "gc-buttons" : "ns2-buttons"))
    let usb = sendInit(led: 1, minimal: false, verbose: false)
    let link = HIDLink()
    let writer = try CaptureWriter(url: URL(fileURLWithPath: base + ".ns2cap"))
    let t0 = DispatchTime.now().uptimeNanoseconds
    func nowMs() -> UInt64 { (DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000 }
    var labels = ""
    func mark(_ s: String) { labels += "\(nowMs())\t\(s)\n" }
    var word: UInt32 = 0
    var reports = 0
    link.onReport = { r, _ in
        guard r.count >= 6, r[0] == reportID else { return }
        word = UInt32(r[3]) | UInt32(r[4]) << 8 | UInt32(r[5]) << 16
        reports += 1
        writer.append(r)
    }
    do { try link.start() } catch { fail("\(error)") }
    runLoop(seconds: 0.5)
    guard reports > 0 else { fail(String(format: "controller is not streaming (no 0x%02X reports) — replug and retry", reportID)) }

    /// Wait until `cond(word)` holds continuously (same value) for holdMs. nil on timeout.
    func waitFor(timeout: Double, holdMs: Double, _ cond: (UInt32) -> Bool) -> UInt32? {
        let deadline = Date().addingTimeInterval(timeout)
        var since: Date?
        var val: UInt32 = 0
        while Date() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.01, false)
            if cond(word) {
                if since == nil || word != val { since = Date(); val = word }
                if Date().timeIntervalSince(since!) * 1000 >= holdMs { return val }
            } else {
                since = nil
            }
        }
        return nil
    }
    func bits(_ w: UInt32) -> [Int] { (0..<24).filter { w >> $0 & 1 == 1 } }

    // Prompt names, and the bit NS2 Bridge's tables expect for each.
    func bitIndex(_ raw: UInt32) -> Int { raw.trailingZeroBitCount }
    let friendly = ["−": "MINUS (-)", "+": "PLUS (+)", "LS": "LEFT STICK CLICK", "RS": "RIGHT STICK CLICK",
                    "GL": "GL (back-left paddle)", "GR": "GR (back-right paddle)", "↑": "D-PAD UP", "↓": "D-PAD DOWN",
                    "←": "D-PAD LEFT", "→": "D-PAD RIGHT", "L": isGameCube ? "L (press fully, to the click)" : "L",
                    "R": isGameCube ? "R (press fully, to the click)" : "R"]
    let expected: [(name: String, bit: Int)] = isGameCube
        ? GCButtons.named.map { (friendly[$0.1] ?? $0.1, bitIndex($0.0.rawValue)) }
        : ProButtons.named.map { (friendly[$0.1] ?? $0.1, bitIndex($0.0.rawValue)) }
    let names = expected.map(\.name)
    var map: [Int: String] = [:]
    var disagreements: [String] = []
    print("""

    BUTTON TEST — no rush. For each prompt: press and HOLD the button until you see ✓, then let go.
    Take as long as you like (a button is skipped after 45 s of nothing). Keep the sticks centered.

    """)
    if waitFor(timeout: 10, holdMs: 300, { $0 == 0 }) == nil { print("(release all buttons to begin)") }
    for (i, name) in names.enumerated() {
        print(String(format: "[%2d/%d]  Press and hold  ▶ %@", i + 1, names.count, name))
        mark("press \(name)")
        var done = false
        while !done {
            guard let w = waitFor(timeout: 45, holdMs: 400, { $0 != 0 }) else {
                print("        … skipped \(name)"); mark("skip \(name)"); break
            }
            let b = bits(w)
            if b.count > 1 {
                print("        ⚠ \(b.count) buttons held (bits \(b)) — let go and press only \(name)")
            } else if let other = map[b[0]] {
                print("        ⚠ that's the button already recorded as \(other) — let go and press \(name)")
            } else if b[0] != expected[i].bit {
                // Disagrees with NS2 Bridge's table: a slip, or a real difference. Ask for the same press again.
                let known = expected.first { $0.bit == b[0] }?.name ?? "an unknown button"
                print(String(format: "        ? bit %d — NS2 Bridge knows that bit as %@, not %@.", b[0], known, name))
                print("          Let go. If you really pressed \(name), press it again to confirm; otherwise press \(name).")
                _ = waitFor(timeout: 60, holdMs: 250, { $0 == 0 })
                guard let again = waitFor(timeout: 45, holdMs: 400, { $0 != 0 }) else { break }
                let b2 = bits(again)
                if b2 == b {
                    map[b[0]] = name
                    disagreements.append("\(name) = bit \(b[0]) (NS2 Bridge expects bit \(expected[i].bit))")
                    mark("detected \(name) bit \(b[0]) CONFIRMED-DIFFERENT expected \(expected[i].bit)")
                    print("        ✓ confirmed: \(name) = bit \(b[0]) — recorded as a difference")
                    done = true
                } else if b2.count == 1, b2[0] == expected[i].bit {
                    map[b2[0]] = name
                    mark("detected \(name) bit \(b2[0])")
                    print(String(format: "        ✓ %@ = bit %d (matches NS2 Bridge) — let go", name, b2[0]))
                    done = true
                } else {
                    print("        ⚠ still not clear — let's try \(name) again")
                }
            } else {
                map[b[0]] = name
                mark("detected \(name) bit \(b[0])")
                print(String(format: "        ✓ %@ = bit %d  (byte %d, bit %d, matches NS2 Bridge) — let go", name, b[0], 3 + b[0] / 8, b[0] % 8))
                done = true
            }
            _ = waitFor(timeout: 60, holdMs: 250, { $0 == 0 })
        }
        mark("released")
    }

    let summary = map.sorted { $0.key < $1.key }.map { String(format: "  bit %2d  (byte %d.%d)  %@", $0.key, 3 + $0.key / 8, $0.key % 8, $0.value) }
    print("\n=== BUTTON MAP (\(map.count)/\(names.count)) ===\n" + summary.joined(separator: "\n"))
    print(disagreements.isEmpty ? "All pressed buttons match NS2 Bridge's table."
                                : "Confirmed differences from NS2 Bridge's table:\n  " + disagreements.joined(separator: "\n  "))
    let json = "{\n" + map.sorted { $0.key < $1.key }.map { "  \"\($0.key)\": \"\($0.value)\"" }.joined(separator: ",\n") + "\n}\n"
    try json.write(toFile: base + ".json", atomically: true, encoding: .utf8)

    if !skipMotion, let aBit = map.first(where: { $0.value == "A" })?.key {
        let aMask = UInt32(1) << UInt32(aBit)
        func pressA(_ prompt: String) {
            print(prompt)
            _ = waitFor(timeout: 600, holdMs: 60, { $0 & aMask != 0 })
            _ = waitFor(timeout: 60, holdMs: 100, { $0 & aMask == 0 })
        }
        print("\nMOTION TEST (last step) — each step starts and stops when YOU press A.\n")
        let motions = [
            ("PITCH", "tilt the top edge up and down slowly, like nodding"),
            ("ROLL", "tip the left grip down, then the right grip down, slowly"),
            ("YAW", "keep it level and turn it left and right, like a steering wheel lying flat"),
        ]
        pressA("[still]  Put the controller FLAT on the desk. Press A, then let go completely.")
        print("         recording 4 s of stillness — don't touch it…")
        mark("still-flat"); runLoop(seconds: 4, tick: 0.02); mark("still-end")
        for (tag, how) in motions {
            pressA("[\(tag.lowercased())]  Pick it up. Press A to START, then \(how).")
            mark("motion \(tag)"); print("         recording — press A again to STOP")
            pressA("")
            mark("motion-end \(tag)"); print("         ✓ \(tag) saved")
        }
        pressA("[still]  Put it FLAT again. Press A, then let go.")
        print("         recording 4 s — don't touch it…")
        mark("still-flat-2"); runLoop(seconds: 4, tick: 0.02); mark("still-end")
    }
    mark("END")
    link.stop(); usb?.close(); writer.close()
    try labels.write(toFile: base + ".labels", atomically: true, encoding: .utf8)
    print("\n✓ saved \(writer.count) reports → \(base).ns2cap, .labels, .json")

case "serial":
    // Read-only: the controller's serial number from flash 0x13000 (as SDL does).
    let pid = productID()
    guard let usb = try? VendorUSB(productID: pid) else { fail("cannot open interface 1") }
    let reply = try usb.readFlash(0x13000)
    usb.close()
    print("reply \(reply?.count ?? 0) bytes: \(reply.map { Array($0.prefix(48)).hex } ?? "none")")
    print("serial: \(reply.flatMap(NS2Command.serial(fromFlashReply:)) ?? "(not found)")")

case "press":
    // Live readout: prints parsed buttons + sticks whenever they change.
    let seconds = Double(option("--seconds") ?? "30") ?? 30
    let usb = sendInit(led: 1, minimal: false, verbose: false)
    let link = HIDLink()
    var last = ""
    link.onReport = { r, _ in
        guard let s = ControllerState(report: r) else { return }
        let bits = (0..<24).filter { s.buttons.rawValue >> $0 & 1 == 1 }
        let line = "buttons: \(s.buttons.names.joined(separator: " ").padding(toLength: 24, withPad: " ", startingAt: 0)) bits \(bits)"
            + String(format: "   L %4d,%4d  R %4d,%4d", s.left.x / 64 * 64, s.left.y / 64 * 64, s.right.x / 64 * 64, s.right.y / 64 * 64)
            + "   battery \(s.batteryLevel)/9\(s.charging ? " ⚡︎" : "")"
        if line != last { print(line); last = line }
    }
    do { try link.start() } catch { fail("\(error)") }
    print("press buttons / move sticks for \(Int(seconds))s…")
    runLoop(seconds: seconds)
    link.stop(); usb?.close()

case "analyze":
    guard let path = args.first else { fail("usage: analyze /path/to/Game.app") }
    let a = GameAnalyzer.analyze(URL(fileURLWithPath: path))
    print("\(a.headline)\n  verdict: \(a.verdict.rawValue)  hooks: \(a.hooks)  archs: \(a.architectures)")
    for f in a.findings { print("  • \(f)") }

case "hid":
    // Generic raw HID reader for any Nintendo product: ns2probe hid 2019 [--seconds N] [--send "80 02"]...
    guard let pidArg = args.first, let pid = Int(pidArg.replacingOccurrences(of: "0x", with: ""), radix: 16) else {
        fail("usage: hid <pid hex> [--seconds N] [--send \"hex bytes\"]...")
    }
    args.removeFirst()
    var sends: [[UInt8]] = []
    while let s = option("--send") { sends.append(s.split(separator: " ").compactMap { UInt8($0, radix: 16) }) }
    let seconds = Double(option("--seconds") ?? "3") ?? 3
    let link = HIDLink(productIDs: [pid])
    var stats: [UInt8: ByteStats] = [:]
    var counts: [UInt8: Int] = [:]
    var lastByID: [UInt8: [UInt8]] = [:]
    link.onDevice = { up, p in print(String(format: "%@ 057E:%04X", up ? "+" : "-", p)) }
    link.onReport = { r, _ in
        guard let id = r.first else { return }
        counts[id, default: 0] += 1; stats[id, default: ByteStats()].add(r); lastByID[id] = r
    }
    do { try link.start() } catch { fail("\(error)") }
    runLoop(seconds: 0.4)
    for s in sends {
        let rc = link.sendOutput(s)
        print(String(format: "→ %@   (0x%08X)", s.hex, rc))
        runLoop(seconds: 0.15)
    }
    runLoop(seconds: seconds)
    link.stop()
    for (id, n) in counts.sorted(by: { $0.key < $1.key }) {
        print(String(format: "report 0x%02X ×%d (%.0f/s)  last: %@", id, n, Double(n) / seconds, lastByID[id]!.prefix(24).hex))
        print(stats[id]!.report(length: 64))
    }
    if counts.isEmpty { print("no input reports") }

case "interval":
    // Try to change the host polling interval: ns2probe interval <pid hex> <microseconds> [--seconds N]
    guard args.count >= 2, let pid = Int(args[0].replacingOccurrences(of: "0x", with: ""), radix: 16),
          let us = Int(args[1]) else { fail("usage: interval <pid hex> <microseconds> [--seconds N]") }
    args.removeFirst(2)
    let seconds = Double(option("--seconds") ?? "3") ?? 3
    let link = HIDLink(productIDs: [pid])
    var count = 0
    var gaps: [Double] = []
    var last: UInt64 = 0
    link.onReport = { _, ts in
        count += 1
        if last != 0 { gaps.append(Double(ts - last)) }
        last = ts
    }
    do { try link.start() } catch { fail("\(error)") }
    runLoop(seconds: 0.5)
    guard let dev = link.device else { fail("device not found") }
    var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
    func measure(_ label: String) {
        count = 0; gaps = []; last = 0
        runLoop(seconds: seconds)
        let ms = gaps.map { $0 * Double(tb.numer) / Double(tb.denom) / 1e6 }.sorted()
        let mean = ms.isEmpty ? 0 : ms.reduce(0, +) / Double(ms.count)
        print(String(format: "%@: %.0f reports/s · mean interval %.2f ms · p50 %.2f · p99 %.2f   (ReportInterval now %@)",
                     label, Double(count) / seconds, mean, ms.isEmpty ? 0 : ms[ms.count / 2],
                     ms.isEmpty ? 0 : ms[min(ms.count - 1, Int(Double(ms.count) * 0.99))],
                     "\(IOHIDDeviceGetProperty(dev, kIOHIDReportIntervalKey as CFString) ?? "nil" as CFTypeRef)"))
    }
    measure("before")
    let ok = IOHIDDeviceSetProperty(dev, kIOHIDReportIntervalKey as CFString, NSNumber(value: us))
    print("IOHIDDeviceSetProperty(ReportInterval=\(us)) → \(ok)")
    // Also try the registry entry of the HID device service directly.
    let kr = IORegistryEntrySetCFProperty(IOHIDDeviceGetService(dev), kIOHIDReportIntervalKey as CFString, NSNumber(value: us))
    print(String(format: "IORegistryEntrySetCFProperty → 0x%08X", kr))
    measure("after ")
    link.stop()

case "patch-dylib":
    // ns2probe patch-dylib <file> <load path> [--remove]   (re-sign the file afterward)
    let remove = flag("--remove")
    guard args.count >= 2 else { fail("usage: patch-dylib <file> <load path> [--remove]") }
    let url = URL(fileURLWithPath: args[0])
    do {
        if remove { try MachOPatcher.removeDylib(args[1], from: url) } else { try MachOPatcher.addWeakDylib(args[1], to: url) }
        print((try MachOPatcher.loadedDylibs(url)).joined(separator: "\n"))
    } catch { fail("\(error)") }

case "sdl-mapping":
    print(SDLMapping.line())

case "gc":
    let seconds = Double(option("--seconds") ?? "10") ?? 10
    var usb: VendorUSB?
    if flag("--init") { usb = sendInit(led: 1, minimal: false, verbose: false); print("→ init sent") }
    GCController.shouldMonitorBackgroundEvents = true
    func describe(_ c: GCController) {
        print("● \(c.vendorName ?? "?")  category=\(c.productCategory)  extended=\(c.extendedGamepad != nil)  motion=\(c.motion != nil)  haptics=\(c.haptics != nil)  battery=\(c.battery.map { "\(Int($0.batteryLevel * 100))%" } ?? "n/a")")
        c.physicalInputProfile.valueDidChangeHandler = { _, el in
            let name = el.localizedName ?? el.aliases.first ?? "?"
            if let b = el as? GCControllerButtonInput {
                print(String(format: "   %@ = %.2f", name, b.value))
            } else if let d = el as? GCControllerDirectionPad {
                print(String(format: "   %@ = (%.2f, %.2f)", name, d.xAxis.value, d.yAxis.value))
            } else if let a = el as? GCControllerAxisInput {
                print(String(format: "   %@ = %.2f", name, a.value))
            }
        }
    }
    NotificationCenter.default.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { n in
        print("+ connected"); if let c = n.object as? GCController { describe(c) }
    }
    NotificationCenter.default.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { _ in
        print("- disconnected")
    }
    runLoop(seconds: 1)
    print("controllers now: \(GCController.controllers().count)")
    for c in GCController.controllers() { describe(c) }
    print("watching \(seconds)s — press buttons…")
    runLoop(seconds: seconds)
    usb?.close()

case "rumble":
    let preset = args.first.flatMap { Rumble.presets[$0] } ?? Rumble.medium
    let seconds = Double(option("--seconds") ?? "1") ?? 1
    let link = HIDLink()
    do { try link.start() } catch { fail("\(error)") }
    runLoop(seconds: 0.3)
    guard link.device != nil else { fail("HID device not found") }
    var counter = 0
    let frames = Int(seconds * 250)
    var errors = 0
    for _ in 0..<frames {
        if link.sendOutput(Rumble.report(left: preset, right: preset, counter: counter)) != kIOReturnSuccess { errors += 1 }
        counter += 1; usleep(4000)
    }
    for _ in 0..<3 { link.sendOutput(Rumble.report(left: Rumble.neutral, right: Rumble.neutral, counter: counter)); counter += 1; usleep(4000) }
    print(errors == 0 ? "✓ sent \(frames) frames (\(preset.hex))" : "⚠ \(errors)/\(frames) frames failed via IOHIDDeviceSetReport")

case "spi":
    guard let a = args.first, let addr = UInt32(a.replacingOccurrences(of: "0x", with: ""), radix: 16) else { fail("usage: spi <hexaddr> [len]") }
    let len = UInt8(args.dropFirst().first.flatMap { Int($0) } ?? 0x40)
    guard let usb = try? VendorUSB(productID: productID()) else { fail("cannot open interface 1") }
    let c = NS2Command.spiRead(address: addr, length: len)
    print("→ \(c.hex)")
    do {
        let r = try usb.command(c, timeout: 0.5)
        print("← \(r.map { $0.hex } ?? "(no reply)")")
        if let more = usb.read(timeout: 0.2) { print("← \(more.hex)") }
    } catch { print("✗ \(error)") }
    usb.close()

default:
    print(usage)
}
