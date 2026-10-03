import XCTest
@testable import NS2Kit
import simd

final class NS2KitTests: XCTestCase {
    func testRumbleReportLayout() {
        let r = Rumble.report(left: Rumble.strong, right: Rumble.gentle, counter: 0x13)
        XCTAssertEqual(r.count, 64)
        XCTAssertEqual(r[0], 0x02)
        XCTAssertEqual(r[1], 0x53)
        XCTAssertEqual(r[17], 0x53)
        XCTAssertEqual(Array(r[2...6]), Rumble.strong)
        XCTAssertEqual(Array(r[18...22]), Rumble.gentle)
    }

    func testInitSequenceStartsWithHIDOutput() {
        let s = NS2Command.initSequence()
        XCTAssertEqual(s.first?.bytes.prefix(4).map { $0 }, [0x03, 0x91, 0x00, 0x0D])
        XCTAssertEqual(NS2Command.initSequence(includeUnknown: false).count, s.count - 2)
        XCTAssertEqual(NS2Command.setPlayerLED(0x05)[8], 0x05)
    }

    func testParseIdleReport() throws {
        // Real report captured 2026-09-28 (controller at rest, on USB power).
        let hex = "09 52 23 00 00 00 d5 97 86 6f d8 82 38 00 00 1e d3 36 00 0c 00 98 01 13 02 ac 9d ff 80 d0 c8 7b b6 52 1d 00 88 f2 04 fd e0 52 00 10 d6 fe 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00"
        let bytes = hex.split(separator: " ").map { UInt8($0, radix: 16)! }
        let s = try XCTUnwrap(ControllerState(report: bytes))
        XCTAssertEqual(s.counter, 0x52)
        XCTAssertTrue(s.externalPower)
        XCTAssertTrue(s.charging)
        XCTAssertEqual(s.batteryLevel, 8)
        XCTAssertEqual(s.buttons, [])
        XCTAssertEqual(s.left, Stick(x: 2005, y: 2153))
        XCTAssertEqual(s.right, Stick(x: 2159, y: 2093))
        XCTAssertEqual(s.motionLength, 30)
        XCTAssertEqual(s.motion.count, 30)
    }

    func testButtonBits() {
        let s = ControllerState(report: [0x09, 0, 0, 0x02, 0x08, 0x10] + [UInt8](repeating: 0, count: 58))!
        XCTAssertEqual(s.buttons, [.a, .dpadUp, .c])
        XCTAssertNil(ControllerState(report: [0x07] + [UInt8](repeating: 0, count: 63)))   // 0x05 is parsed too (motion)
    }

    func testSDLMappingHasAllButtons() {
        let line = SDLMapping.line()
        for i in 0...20 { XCTAssertTrue(line.contains(":b\(i),"), "missing b\(i)") }
        XCTAssertTrue(line.hasPrefix(SDLMapping.macGUID))
        XCTAssertTrue(line.contains(",a:b0,"))                                  // positions: bottom button is A
        XCTAssertTrue(SDLMapping.line(layout: .labels).contains(",a:b1,"))     // labels: Nintendo A is A
    }

    func testStickCalibration() {
        let cal = StickCalibration(x: .default, y: .default, deadzone: 0.1)
        XCTAssertEqual(cal.apply(Stick(x: 2048, y: 2048)).x, 0)
        XCTAssertEqual(cal.apply(Stick(x: 2100, y: 2048)).x, 0)             // inside deadzone
        XCTAssertEqual(cal.apply(Stick(x: 3584, y: 2048)).x, 1, accuracy: 1e-9)
        XCTAssertEqual(cal.apply(Stick(x: 384, y: 2048)).x, -1, accuracy: 1e-9)
        XCTAssertEqual(cal.apply(Stick(x: 2048, y: 3584)).y, 1, accuracy: 1e-9)   // up = +1
        XCTAssertEqual(cal.apply(Stick(x: 4095, y: 2048)).x, 1, accuracy: 1e-9)   // clamps
    }

    func testCalibrationRecorder() {
        var rec = CalibrationRecorder()
        for _ in 0..<10 { rec.addCenter(Stick(x: 2000, y: 2100)) }
        XCTAssertFalse(rec.rangeIsGood)
        for (x, y) in [(400, 2100), (3600, 2100), (2000, 450), (2000, 3650)] { rec.addRange(Stick(x: UInt16(x), y: UInt16(y))) }
        XCTAssertTrue(rec.rangeIsGood)
        let cal = try! XCTUnwrap(rec.result(deadzone: 0.05))
        XCTAssertEqual(cal.x.center, 2000)
        XCTAssertEqual(cal.apply(Stick(x: 3600, y: 2100)).x, 1, accuracy: 1e-9)
    }

    func testHapticsEngineSendsThenGoesQuiet() {
        let lock = NSLock()
        var reports: [[UInt8]] = []
        let engine = HapticsEngine { r in lock.withLock { reports.append(r) } }
        engine.play(.tap)                       // 40 ms at 0.9
        Thread.sleep(forTimeInterval: 0.25)
        let snapshot = lock.withLock { reports }
        XCTAssertGreaterThan(snapshot.count, 5)
        XCTAssertEqual(snapshot.first?[0], 0x02)
        XCTAssertEqual(HDRumble2Encoder.unpack(Array(snapshot.first![2...6])).hiAmp, 405)   // 0.9 × 450
        XCTAssertEqual(HDRumble2Encoder.unpack(Array(snapshot.last![2...6])).hiAmp, 0)      // ends silent
        XCTAssertEqual(HDRumble2Encoder.unpack(Array(snapshot.last![2...6])).loAmp, 0)
        let countAfterIdle = snapshot.count
        Thread.sleep(forTimeInterval: 0.1)
        XCTAssertEqual(lock.withLock { reports.count }, countAfterIdle)    // timer stopped
    }

    func testHDRumble2EncodingMatchesKernelAndSDL() {
        let e = HDRumble2Encoder()
        XCTAssertEqual(e.encode(HapticLevel(1.0)), [0x87, 0x09, 0x27, 0x91, 0x70])   // full, capped at 450
        XCTAssertEqual(e.encode(.off), [0x87, 0x01, 0x20, 0x11, 0x00])              // silent frame
        // The canned "strong" pattern from procon2tool decodes into sane fields.
        let s = HDRumble2Encoder.unpack(Rumble.strong)
        XCTAssertEqual(s.hiFreq, 0x193); XCTAssertEqual(s.hiAmp, 397)
        XCTAssertEqual(s.loFreq, 0x1C3); XCTAssertEqual(s.loAmp, 52)
        // Round trip.
        let p = HDRumble2Encoder.pack(hiFreq: 0x2AB, hiAmp: 0x155, loFreq: 0x0F0, loAmp: 0x1C2)
        let u = HDRumble2Encoder.unpack(p)
        XCTAssertEqual([u.hiFreq, u.hiAmp, u.loFreq, u.loAmp], [0x2AB, 0x155, 0x0F0, 0x1C2])
    }

    func testLatencyMonitorCountsDrops() {
        let m = LatencyMonitor()
        for c: UInt8 in [1, 2, 3, 6, 7] { m.record([0x09, c] + [UInt8](repeating: 0, count: 62), link: .usb) }
        let s = m.snapshot()
        XCTAssertEqual(s.received, 5)
        XCTAssertEqual(s.dropped, 2)          // 4 and 5 missing
        XCTAssertEqual(s.samples, 4)
        m.record([0x09, 0], link: .usb)       // wrap 7 → 0: 255 steps, treated as a reset, not a drop burst
        XCTAssertEqual(m.snapshot().dropped, 2)
    }

    func testSwitch1RumbleEncoding() {
        XCTAssertEqual(Switch1Rumble.encode(high: 1, low: 1), [0x00, 0xC9, 0x40, 0x72])   // verified on the N64 controller
        XCTAssertEqual(Switch1Rumble.encode(high: 0, low: 0), Switch1Rumble.neutral)
        XCTAssertEqual(Switch1Rumble.report(left: Switch1Rumble.neutral, right: Switch1Rumble.neutral, counter: 18),
                       [0x10, 0x02, 0x00, 0x01, 0x40, 0x40, 0x00, 0x01, 0x40, 0x40])
        let half = Switch1Rumble.encode(high: 0.5, low: 0.5)
        XCTAssertLessThan(half[1] & 0xFE, 0xC8)   // weaker than full
        XCTAssertGreaterThan(half[1] & 0xFE, 0)
    }

    func testN64ReportParse() throws {
        // Idle report captured from the real controller.
        let idle: [UInt8] = [0x30, 0x65, 0x91, 0x00, 0x80, 0x00, 0xCF, 0xF7, 0x89, 0x00, 0x00, 0x00] + [UInt8](repeating: 0, count: 52)
        let s = try XCTUnwrap(N64State(report: idle))
        XCTAssertEqual(s.buttons, [])
        XCTAssertEqual(s.stick, Stick(x: 1999, y: 2207))
        // A + C-down (ZR) + Start (+) + Z (ZL) + D-up
        let r: [UInt8] = [0x30, 0, 0, 0x08 | 0x80, 0x02, 0x80 | 0x02] + [UInt8](repeating: 0, count: 58)
        XCTAssertEqual(N64State(report: r)!.buttons, [.a, .cDown, .start, .z, .up])
    }

    func testN64MappingPerEngine() {
        let recomp = try! XCTUnwrap(N64Mapping.line(for: .n64recomp))
        let lus = try! XCTUnwrap(N64Mapping.line(for: .libultraship))
        XCTAssertTrue(recomp.hasPrefix(N64Mapping.sdl2GUID))
        XCTAssertTrue(recomp.contains(",x:b1,"))          // B → west for recomp
        XCTAssertTrue(lus.contains(",b:b1,"))             // B → east for libultraship
        for l in [recomp, lus] {
            XCTAssertTrue(l.contains("+righty:+a5"))       // C-down
            XCTAssertTrue(l.contains("lefttrigger:a4"))    // Z
        }
        XCTAssertNil(N64Mapping.line(for: .unknown))
    }

    func testProfileStore() {
        var store = ProfileStore()
        XCTAssertEqual(store.profiles.count, ControllerKind.allCases.count)          // one Default per kind
        XCTAssertEqual(store.activeProfile(for: .n64).sticks.count, 1)
        XCTAssertEqual(store.activeProfile(for: .switch2Pro).sticks.count, 2)
        var p = store.activeProfile(for: .n64)
        p.hapticsIntensity = 0.4
        store.update(p)
        let racing = store.add(name: "Racing", kind: .n64)                           // copies active settings
        XCTAssertEqual(store.activeProfile(for: .n64).id, racing.id)
        XCTAssertEqual(racing.hapticsIntensity, 0.4)
        store.delete(racing.id)
        XCTAssertEqual(store.activeProfile(for: .n64).name, "Default")               // falls back
        store.delete(store.activeProfile(for: .n64).id)                               // last one: refused
        XCTAssertEqual(store.profiles(for: .n64).count, 1)
        let data = try! JSONEncoder().encode(store)
        XCTAssertEqual(try! JSONDecoder().decode(ProfileStore.self, from: data), store)
    }

    func testControllerInputParsing() {
        let n64: [UInt8] = [0x30, 0x65, 0x91, 0x08, 0x00, 0x00, 0xCF, 0xF7, 0x89] + [UInt8](repeating: 0, count: 55)
        let i = try! XCTUnwrap(ControllerInput.parse(n64, kind: .n64))
        XCTAssertEqual(i.pressed, ["A"])
        XCTAssertEqual(i.sticks.count, 1)
        XCTAssertNil(ControllerInput.parse(n64, kind: .switch2Pro))                   // wrong report ID
        XCTAssertEqual(ControllerKind(productID: 0x2019), .n64)
        XCTAssertEqual(ControllerKind(productID: 0x2069), .switch2Pro)
        XCTAssertEqual(ControllerKind(productID: 0x2073), .gameCube)
        XCTAssertNil(ControllerKind(productID: 0x2066))                                 // Joy-Con 2: later
    }

    func testBatteryCurveAndRecord() {
        let c = BatteryCurve.typicalLiPo
        XCTAssertEqual(c.percent(millivolts: 4200), 100)
        XCTAssertEqual(c.percent(millivolts: 3000), 0)
        XCTAssertEqual(c.percent(millivolts: 3840), 50, accuracy: 0.001)
        XCTAssertEqual(c.percent(millivolts: 4152), 95.2, accuracy: 0.1)            // the N64 reading
        // Charging from 3750 to 4020 mV over 30 min → 25 % → 80 % = 0.55 cycles.
        var rec = BatteryRecord(key: "n64-test", kind: .n64, now: Date(timeIntervalSince1970: 0))
        for i in 0...30 {
            let mv = 3750 + Int(Double(i) * 9)
            rec.add(BatteryReading(millivolts: mv, level: 0.5, charging: true, externalPower: true),
                    at: Date(timeIntervalSince1970: Double(i) * 60))
        }
        XCTAssertEqual(rec.cycles, 0.55, accuracy: 0.02)
        XCTAssertEqual(rec.chargingSeconds, 1800, accuracy: 1)
        XCTAssertEqual(rec.samples.count, 31)
        let rate = try! XCTUnwrap(rec.ratePerHour(now: Date(timeIntervalSince1970: 1800)))
        XCTAssertGreaterThan(rate, 80)                                                  // ~110 %/h
    }

    func testCalibrationRunBuildsMonotonicCurve() {
        var run = CalibrationRun()
        let t0 = Date(timeIntervalSince1970: 0)
        run.add(BatteryReading(millivolts: 4190, level: 1, charging: false, externalPower: true), at: t0)
        XCTAssertEqual(run.stage, .discharging)
        // 3 h linear-ish discharge 4150 → 3450 mV
        for i in 0...180 {
            let mv = 4150 - Int(Double(i) * 700 / 180)
            run.add(BatteryReading(millivolts: mv, level: 0.5, charging: false, externalPower: false),
                    at: t0.addingTimeInterval(Double(i) * 60))
        }
        XCTAssertEqual(run.stage, .done)
        let curve = try! XCTUnwrap(run.curve())
        XCTAssertTrue(curve.measured)
        for i in 1..<curve.points.count {
            XCTAssertGreaterThanOrEqual(curve.points[i][0], curve.points[i - 1][0])
            XCTAssertGreaterThanOrEqual(curve.points[i][1], curve.points[i - 1][1])
        }
        XCTAssertGreaterThan(curve.percent(millivolts: 3900), curve.percent(millivolts: 3600))
    }

    func testOctagonalGateKeepsDiagonals() {
        let a = AxisCal(min: 1000, center: 2000, max: 3000)
        let cal = StickCalibration(x: a, y: a, deadzone: 0)
        let diag = Stick(x: 2810, y: 2810)                            // 0.81 on each axis, like an N64 diagonal notch
        let oct = cal.apply(diag, octagonal: true)
        XCTAssertEqual(oct.x, 0.81, accuracy: 0.001)                  // kept, not squashed
        let round = cal.apply(diag)
        XCTAssertEqual(round.x, 0.7071, accuracy: 0.001)              // circular gate clamps the radius
        XCTAssertEqual(cal.apply(Stick(x: 3000, y: 2000), octagonal: true).x, 1, accuracy: 1e-9)
    }

    func testMachOPatcherRoundTrip() throws {
        // Build a real universal dylib, add the helper as a weak dependency, verify, then remove it.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ns2-macho-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("t.c"), lib = dir.appendingPathComponent("libT.dylib")
        try "int t(void){return 1;}".write(to: src, atomically: true, encoding: .utf8)
        let cc = Process()
        cc.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        cc.arguments = ["-dynamiclib", "-arch", "arm64", "-arch", "x86_64", "-Wl,-headerpad,0x200", "-o", lib.path, src.path]
        try cc.run(); cc.waitUntilExit()
        XCTAssertEqual(cc.terminationStatus, 0)

        let hook = "@loader_path/ns2rumble.dylib"
        XCTAssertFalse(try MachOPatcher.loadedDylibs(lib).contains(hook))
        try MachOPatcher.addWeakDylib(hook, to: lib)
        XCTAssertTrue(try MachOPatcher.loadedDylibs(lib).contains(hook))
        try MachOPatcher.addWeakDylib(hook, to: lib)                                   // idempotent
        XCTAssertEqual(try MachOPatcher.loadedDylibs(lib).filter { $0 == hook }.count, 1)
        let otool = Process(); let pipe = Pipe()
        otool.executableURL = URL(fileURLWithPath: "/usr/bin/otool")
        otool.arguments = ["-arch", "x86_64", "-L", lib.path]; otool.standardOutput = pipe
        try otool.run(); otool.waitUntilExit()
        XCTAssertTrue(String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).contains(hook))
        try MachOPatcher.removeDylib(hook, from: lib)
        XCTAssertFalse(try MachOPatcher.loadedDylibs(lib).contains(hook))
    }

    func testConfigDescriptorParse() {
        // config header + iface0 (HID, 2 EPs) + iface1 (vendor, 2 bulk EPs)
        let bytes: [UInt8] = [
            9, 2, 50, 0, 2, 1, 0, 0x80, 250,
            9, 4, 0, 0, 2, 3, 0, 0, 0,
            7, 5, 0x81, 3, 64, 0, 4,
            7, 5, 0x01, 3, 64, 0, 4,
            9, 4, 1, 0, 2, 0xFF, 0, 0, 0,
            7, 5, 0x82, 2, 64, 0, 0,
            7, 5, 0x02, 2, 64, 0, 0,
        ]
        let c = USBConfigInfo(bytes: bytes)
        XCTAssertEqual(c.interfaces.count, 2)
        XCTAssertEqual(c.interfaces[1].cls, 0xFF)
        XCTAssertEqual(c.interfaces[1].endpoints.map(\.transfer), ["bulk", "bulk"])
        XCTAssertTrue(c.interfaces[0].endpoints[0].isIn)
    }

    func testBluetoothSpeedLevelsAndExpectations() {
        // bluetoothd levels verified on hardware: -12 → 7.5 ms (133 Hz), -7 → 15 ms, 0 → macOS's 30 ms.
        XCTAssertEqual(BluetoothSpeed.fastest.latencyLevel, -12)   // not -25: its events are too short for a report
        XCTAssertEqual(BluetoothSpeed.fast.latencyLevel, -7)
        XCTAssertEqual(BluetoothSpeed.standard.latencyLevel, 0)
        XCTAssertEqual(LatencyMonitor.expectation(for: .bluetooth, bluetoothIntervalMs: 7.5).intervalMs, 7.5)
        XCTAssertEqual(LatencyMonitor.expectation(for: .bluetooth).intervalMs, 30)
        XCTAssertEqual(LatencyMonitor.expectation(for: .bluetooth, kind: .n64, bluetoothIntervalMs: 7.5).intervalMs, 15)  // classic BT, own rate
        XCTAssertEqual(LatencyMonitor.expectation(for: .usb, bluetoothIntervalMs: 7.5).intervalMs, 4)
    }

    func testBLEDebugChannelNeverWritesMemory() {
        XCTAssertTrue(BLELink.debugAllowed([0x0C, 0x91, 0x01, 0x01, 0x00, 0x04, 0x00, 0x00, 0x2F, 0, 0, 0]))  // feature info
        XCTAssertTrue(BLELink.debugAllowed([0x02, 0x91, 0x01, 0x04, 0x00, 0x08, 0x00, 0x00]))                // flash read
        XCTAssertFalse(BLELink.debugAllowed([0x02, 0x91, 0x01, 0x02, 0x00, 0x48, 0x00, 0x00]))               // flash write
        XCTAssertFalse(BLELink.debugAllowed([0x02, 0x91, 0x01, 0x03, 0x00, 0x08, 0x00, 0x00]))               // flash erase
        XCTAssertFalse(BLELink.debugAllowed([0x0D, 0x91, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00]))               // firmware update
        XCTAssertFalse(BLELink.debugAllowed([0x15, 0x91, 0x01, 0x01, 0x00, 0x00, 0x00, 0x00]))               // pairing
        XCTAssertFalse(BLELink.debugAllowed([0x03, 0x91, 0x01, 0x0D, 0x00, 0x08, 0x00, 0x00]))               // USB init + address
    }

    func testVirtualGamepadPacketMatchesHelperLayout() {
        var pad = DSUServer.Pad()
        pad.south = true; pad.home = true; pad.dpadLeft = true
        pad.leftStick = SIMD2(1, 1)                                        // right and up
        pad.r2 = true
        pad.motion = MotionSample(timestampMicros: 1_000_000, accel: SIMD3(0, 1, 0), gyro: SIMD3(0, 0, 90), temperatureC: 25)
        let g = VirtualGamepad(slot: 1, kind: .switch2Pro, pad: pad, layout: .positions)
        XCTAssertEqual(g.buttons, 1 << 0 | 1 << 5 | 1 << 13)              // south, guide, dpad left
        XCTAssertEqual(g.axes, [32767, -32767, 0, 0, -32768, 32767])        // SDL: up is negative; triggers rest at min
        let p = VirtualGamepad.packet([g])
        XCTAssertEqual(p.count, 6 + 52)                                     // ns2rumble.c parses 52-byte entries
        XCTAssertEqual(Array(p[0..<6]), Array("NS2V".utf8) + [1, 1])
        XCTAssertEqual(p[6], 1); XCTAssertEqual(p[7], 1)                    // slot, motion flag
        XCTAssertEqual(UInt16(p[8]) | UInt16(p[9]) << 8, 0x2069)
        let accelY = Float(bitPattern: UInt32(p[30]) | UInt32(p[31]) << 8 | UInt32(p[32]) << 16 | UInt32(p[33]) << 24)
        XCTAssertEqual(accelY, 9.80665, accuracy: 0.001)                    // m/s²
        let gyroZ = Float(bitPattern: UInt32(p[46]) | UInt32(p[47]) << 8 | UInt32(p[48]) << 16 | UInt32(p[49]) << 24)
        XCTAssertEqual(gyroZ, .pi / 2, accuracy: 0.0001)                    // rad/s
        // Label layout: the button printed "A" (east on the Pro) becomes SDL's A.
        var a = DSUServer.Pad(); a.east = true
        XCTAssertEqual(VirtualGamepad(slot: 1, kind: .switch2Pro, pad: a, layout: .labels).buttons, 1 << 0)
    }

    func testRumbleRouteToBluetoothController() {
        let routes = [RumbleRoute(productID: 0x2069, player: 1, deviceID: 42, item: "usb"),
                      RumbleRoute(productID: 0x2069, player: 2, deviceID: nil, item: "ble")]
        XCTAssertEqual(RumbleRoute.choose(routes, productID: 0x2069, deviceID: RumbleRoute<String>.bluetoothDevice, rank: -1), "ble")
        XCTAssertEqual(RumbleRoute.choose(routes, productID: 0x2069, deviceID: 42, rank: -1), "usb")
    }

    func testDemoReport05RoundTripsThroughTheDecoder() {
        var r09 = [UInt8](repeating: 0, count: 64)
        r09[0] = 0x09; r09[2] = 7 << 2                                      // battery level 7
        let b = ProButtons([.a, .zl, .home, .dpadUp]).rawValue
        r09[3] = UInt8(b & 0xFF); r09[4] = UInt8(b >> 8 & 0xFF); r09[5] = UInt8(b >> 16 & 0xFF)
        r09[6...11] = [0x00, 0x08, 0x80, 0xFF, 0x0F, 0x40]
        let m = DemoMotion.sample(at: 1.3)
        let r05 = Report05.make(from: r09, accel: m.accel, gyro: m.gyro, micros: 123_456)!
        let s05 = ControllerState(report05: r05)!, s09 = ControllerState(report: r09)!
        XCTAssertEqual(s05.buttons, s09.buttons)
        XCTAssertEqual(s05.left, s09.left); XCTAssertEqual(s05.right, s09.right)
        let d = MotionDecoder().decode(r05)!
        XCTAssertEqual(d.timestampMicros, 123_456)
        XCTAssertEqual(simd_length(d.accel - m.accel), 0, accuracy: 0.001)   // 1 LSB ≈ 0.00024 g
        XCTAssertEqual(simd_length(d.gyro - m.gyro), 0, accuracy: 0.1)       // 1 LSB ≈ 0.06 °/s
        XCTAssertEqual(simd_length(m.accel), 1, accuracy: 1e-9)              // gravity only
    }

    func testBLECommandQueueWaitsForEachReply() {
        var q = BLECommandQueue()
        var ran: [String] = []
        let mask: [UInt8] = [0x0C, 0x91, 0x01, 0x02, 0x00, 0x04, 0x00, 0x00, 0x2F, 0, 0, 0]
        let enable: [UInt8] = [0x0C, 0x91, 0x01, 0x04, 0x00, 0x04, 0x00, 0x00, 0x2F, 0, 0, 0]
        func sent(_ out: [BLECommandQueue.Output]) -> [[UInt8]] {
            out.compactMap { if case .send(let c) = $0 { return c } else if case .run(let a) = $0 { a(); return nil } else { return nil } }
        }
        // Only the first command goes out; the second waits for the first one's reply.
        XCTAssertEqual(sent(q.enqueue([.command(mask), .command(enable), .run { ran.append("descriptor") }])), [mask])
        XCTAssertEqual(q.awaiting?.command, 0x0C); XCTAssertEqual(q.awaiting?.sub, 0x02)
        XCTAssertTrue(sent(q.enqueue([.command(enable)])).isEmpty)                   // busy: queued, nothing sent
        XCTAssertNil(q.reply([0x0B, 0x01, 0x01, 0x03, 0x10, 0x78, 0, 0]))            // a battery reply: not ours
        XCTAssertNil(q.reply([0x0C, 0x01, 0x01, 0x04]))                              // wrong subcommand
        XCTAssertEqual(sent(q.reply([0x0C, 0x01, 0x01, 0x02, 0x10, 0x78, 0, 0])!), [enable])
        // A timeout carries on; the action between commands runs in order.
        XCTAssertEqual(sent(q.timedOut()), [enable])
        XCTAssertEqual(ran, ["descriptor"])
        XCTAssertTrue(sent(q.reply([0x0C, 0x01, 0x01, 0x04])!).isEmpty)
        XCTAssertTrue(q.isIdle)
        _ = q.enqueue([.command(mask), .command(enable)]); q.reset()
        XCTAssertTrue(q.isIdle)
    }

    func testBluetoothSpeedFallbackThreshold() {
        XCTAssertFalse(BluetoothSpeed.fallsBack(reportsIn3Seconds: 400))          // 7.5 ms working (133/s)
        XCTAssertFalse(BluetoothSpeed.fallsBack(reportsIn3Seconds: 200))          // even 15 ms would pass
        XCTAssertTrue(BluetoothSpeed.fallsBack(reportsIn3Seconds: 12))            // the collapse seen at level −25
    }

    func testDiagnosticsScrubsPersonalData() {
        // Built from pieces so the repository's own privacy scan doesn't flag these made-up values.
        let users = "/" + "Users/", serial = "H" + "AA" + "12345678901", mail = "alex" + "@" + "example.com"
        let raw = """
        game: \(users)alex/Games/WaveRace.app · other: \(users)sam/x
        N64 0A:1B:2C:3D:4E:5F · serial \(serial) · mail \(mail)
        keep: 127.0.0.1:26760 · 0x2069 · 12:34:56.789 · ~/Library
        """
        let s = Diagnostics.scrub(raw, home: users + "alex")
        XCTAssertFalse(s.contains("alex")); XCTAssertFalse(s.contains("sam/"))
        XCTAssertTrue(s.contains("~/Games/WaveRace.app")); XCTAssertTrue(s.contains(users + "…/x"))
        XCTAssertTrue(s.contains("0A:1B:2C:••:••:••")); XCTAssertFalse(s.contains("3D:4E:5F"))
        XCTAssertTrue(s.contains("[serial]")); XCTAssertTrue(s.contains("[email]"))
        XCTAssertTrue(s.contains("127.0.0.1:26760")); XCTAssertTrue(s.contains("12:34:56.789"))   // times aren't addresses
    }

    func testUpdateCheckComparesVersionsAndParsesGitHub() {
        XCTAssertTrue(UpdateCheck.isNewer("v1.1.0", than: "1.0.1"))
        XCTAssertTrue(UpdateCheck.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertFalse(UpdateCheck.isNewer("1.1.0", than: "1.1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.1", than: "1.1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.0.9", than: "1.1.0"))
        let json = """
        {"tag_name": "v1.2.0", "html_url": "https://github.com/info-moed/NS2Bridge/releases/tag/v1.2.0", "body": "Notes",
         "assets": [{"name": "NS2Bridge-macOS.zip", "browser_download_url": "https://example.invalid/a.zip"},
                    {"name": "NS2Bridge-1.2.0-macOS.zip", "browser_download_url": "https://example.invalid/b.zip"}]}
        """
        let r = UpdateCheck.parse(Data(json.utf8))
        XCTAssertEqual(r?.version, "1.2.0")
        XCTAssertEqual(r?.notes, "Notes")
        XCTAssertEqual(r?.download?.absoluteString, "https://example.invalid/b.zip")
        XCTAssertNil(UpdateCheck.parse(Data("{}".utf8)))
    }

    func testChangelogSection() {
        let text = """
        # Changelog

        ## [1.1.0] - 2026-10-04

        ### Added
        - Demo mode.

        ## [1.0.1] - 2026-10-01

        - Bluetooth in games.

        ## 1.0.0

        - First release.
        """
        XCTAssertEqual(Changelog.section(text, version: "1.1.0"), "### Added\n- Demo mode.")
        XCTAssertEqual(Changelog.section(text, version: "1.0.1"), "- Bluetooth in games.")
        XCTAssertEqual(Changelog.section(text, version: "1.0.0"), "- First release.")
        XCTAssertNil(Changelog.section(text, version: "1.0"))        // no prefix matches: 1.0 isn't 1.0.1
        XCTAssertNil(Changelog.section(text, version: "2.0.0"))
    }
}
