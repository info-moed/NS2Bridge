import XCTest
import simd
import zlib
@testable import NS2Kit

/// Report 0x05, motion, the GameCube controller and the DSU server. Layouts come from public sources
/// (see Motion.swift / GameCube.swift); these tests pin our parsing to those layouts.
final class MotionAndGameCubeTests: XCTestCase {

    // MARK: Report 0x05

    /// A synthetic 0x05 report: controller flat on a table (+1 g), turning slowly (pitch +61 °/s).
    private func report05(ticks: UInt32 = 1_000_000, buttons: [UInt8] = [0, 0, 0, 0],
                          accel: (Int16, Int16, Int16) = (0, 0, -4096),
                          gyro: (Int16, Int16, Int16) = (1000, 0, 0), mv: UInt16 = 3900) -> [UInt8] {
        var r = [UInt8](repeating: 0, count: 64)
        r[0] = 0x05
        r[1] = 7
        r.replaceSubrange(5...8, with: buttons)
        // sticks centered (2048, 2048)
        r.replaceSubrange(11...16, with: [0x00, 0x08, 0x80, 0x00, 0x08, 0x80])
        func put16(_ o: Int, _ v: UInt16) { r[o] = UInt8(v & 0xFF); r[o + 1] = UInt8(v >> 8) }
        func puts(_ o: Int, _ v: Int16) { put16(o, UInt16(bitPattern: v)) }
        put16(32, mv)
        for i in 0..<4 { r[43 + i] = UInt8((ticks >> (8 * UInt32(i))) & 0xFF) }
        puts(47, 127)                                  // ≈ +1 °C over 25
        puts(49, accel.0); puts(51, accel.1); puts(53, accel.2)
        puts(55, gyro.0); puts(57, gyro.1); puts(59, gyro.2)
        return r
    }

    func testReport05Buttons() {
        // byte 5: A (0x08) + ZR (0x80); byte 6: Home (0x10); byte 7: ↑ (0x02) + ZL (0x80); byte 8: GL (0x02)
        let r = report05(buttons: [0x88, 0x10, 0x82, 0x02])
        XCTAssertEqual(Report05.proButtons(r), [.a, .zr, .home, .dpadUp, .zl, .gl])
        let s = ControllerState(report: r)
        XCTAssertEqual(s?.buttons, [.a, .zr, .home, .dpadUp, .zl, .gl])
        XCTAssertEqual(s?.left, Stick(x: 2048, y: 2048))
        XCTAssertEqual(s?.millivolts, 3900)
        XCTAssertEqual(ControllerInput.parse(r, kind: .switch2Pro)?.pressed, ["A", "ZR", "HOME", "↑", "ZL", "GL"])
    }

    func testMotionDecodeInSDLFrame() throws {
        // SDL: accel = (raw49, raw53, −raw51); gyro = (raw55, raw59, −raw57).
        let r = report05(accel: (100, -4096, 0), gyro: (1000, 200, -300))
        let m = try XCTUnwrap(MotionDecoder().decode(r))
        XCTAssertEqual(m.accel.x, 100 * 8 / 32767, accuracy: 1e-9)
        XCTAssertEqual(m.accel.y, 0, accuracy: 1e-9)
        XCTAssertEqual(m.accel.z, 4096 * 8 / 32767, accuracy: 1e-9)
        let dps = 34.8 / 32767 * 180 / .pi                // ≈ 1/16.4
        XCTAssertEqual(dps, 1 / 16.4, accuracy: 0.0005)
        XCTAssertEqual(m.gyro.x, 1000 * dps, accuracy: 1e-9)
        XCTAssertEqual(m.gyro.y, -300 * dps, accuracy: 1e-9)
        XCTAssertEqual(m.gyro.z, -200 * dps, accuracy: 1e-9)
        XCTAssertEqual(m.temperatureC, 26, accuracy: 0.01)
        XCTAssertEqual(m.timestampMicros, 1_000_000)
    }

    func testMotionDecoderIgnoresReportsWithoutIMU() {
        XCTAssertNil(MotionDecoder().decode(report05(ticks: 0)))
        XCTAssertNil(MotionDecoder().decode([0x09] + [UInt8](repeating: 0, count: 63)))
    }

    func testMotionDecoderClockDetection() {
        // Microsecond IMU clock: 4000 ticks per 4 ms → SDL's 34.8 rad/s range.
        let us = MotionDecoder()
        for i in 0..<200 { _ = us.decode(report05(ticks: 1_000 + UInt32(i) * 4_000), hostNanos: UInt64(i) * 4_000_000) }
        XCTAssertTrue(us.clockChecked)
        XCTAssertEqual(us.gyroRangeRadPerSec, 34.8)
        XCTAssertEqual(us.ticksPerSecond, 1_000_000)
        // Some other clock rate → SDL's 40.0 rad/s range and timestamps rescaled to µs.
        let other = MotionDecoder()
        for i in 0..<200 { _ = other.decode(report05(ticks: 1_000 + UInt32(i) * 1_000), hostNanos: UInt64(i) * 4_000_000) }
        XCTAssertTrue(other.clockChecked)
        XCTAssertEqual(other.gyroRangeRadPerSec, 40.0)
        XCTAssertEqual(other.ticksPerSecond, 250_000, accuracy: 1)
    }

    func testMotionTimestampSurvivesWrap() throws {
        let d = MotionDecoder()
        _ = d.decode(report05(ticks: 0xFFFF_F000))
        let m = try XCTUnwrap(d.decode(report05(ticks: 0x0000_0100)))
        XCTAssertEqual(m.timestampMicros, 0x1_0000_0100)
    }

    func testGyroCalibrator() {
        func sample(_ g: SIMD3<Double>) -> MotionSample {
            MotionSample(timestampMicros: 0, accel: .zero, gyro: g, temperatureC: 25)
        }
        var still = GyroCalibrator()
        for i in 0..<150 { still.add(sample(SIMD3(0.8 + Double(i % 3) * 0.1, -0.2, 0.05))) }
        let b = still.result()
        XCTAssertNotNil(b)
        XCTAssertEqual(b?.x ?? 0, 0.9, accuracy: 0.01)
        XCTAssertEqual(b?.y ?? 0, -0.2, accuracy: 0.01)

        var moving = GyroCalibrator()
        for i in 0..<150 { moving.add(sample(SIMD3(Double(i % 2) * 40, 0, 0))) }
        XCTAssertNil(moving.result(), "a controller that moved must not be accepted")

        var short = GyroCalibrator()
        for _ in 0..<10 { short.add(sample(.zero)) }
        XCTAssertNil(short.result())
    }

    func testInitSequenceSelectsFormat() {
        XCTAssertEqual(NS2Command.initSequence().last?.bytes[8], 0x09)
        XCTAssertEqual(NS2Command.initSequence(format: 0x05).last?.bytes[8], 0x05)
        XCTAssertEqual(NS2Command.initSequence(format: 0x0A).last?.name, "REPORT_FORMAT_0A")
    }

    // MARK: GameCube

    func testGameCubeKind() {
        XCTAssertEqual(ControllerKind(productID: 0x2073), .gameCube)
        XCTAssertTrue(ControllerKind.gameCube.needsInit)
        XCTAssertFalse(ControllerKind.gameCube.hasMotion)
        XCTAssertEqual(ControllerKind.gameCube.nativeReportFormat, 0x0A)
        XCTAssertEqual(ControllerKind.switch2Pro.nativeReportFormat, 0x09)
        XCTAssertEqual(ControllerKind.gameCube.stickNames.count, 2)
    }

    func testGameCubeReport() throws {
        var r = [UInt8](repeating: 0, count: 64)
        r[0] = 0x0A; r[1] = 3
        r[2] = 0x23                                   // USB power, charging, level 8
        r[3] = 0x22                                   // A (0x02) + Z (0x20)   (verified on hardware)
        r[4] = 0x18                                   // ↑ (0x08) + L click (0x10)
        r[5] = 0x10                                   // C
        r.replaceSubrange(6...11, with: [0xFF, 0x0F, 0x00, 0x00, 0x08, 0x80])   // main (4095, 0), C (2048, 2048)
        r[13] = 200; r[14] = 30
        let s = try XCTUnwrap(GCState(report: r))
        XCTAssertEqual(s.buttons, [.a, .z, .up, .l, .c])
        XCTAssertEqual(s.main, Stick(x: 4095, y: 0))
        XCTAssertEqual(s.cStick, Stick(x: 2048, y: 2048))
        XCTAssertEqual(s.batteryLevel, 8)
        XCTAssertTrue(s.charging)
        XCTAssertEqual(s.leftTrigger, 200)
        let i = try XCTUnwrap(ControllerInput.parse(r, kind: .gameCube))
        XCTAssertEqual(i.pressed, ["A", "Z", "↑", "L", "C"])
        XCTAssertEqual(i.triggers.count, 2)
        XCTAssertNil(ControllerInput.parse(r, kind: .switch2Pro), "0x0A is not a Pro report")
    }

    func testTriggerCalibration() {
        var t = TriggerCal()
        XCTAssertEqual(t.normalize(30), 0)           // first value becomes the zero
        XCTAssertEqual(t.normalize(32), 0)           // inside the small deadzone
        XCTAssertEqual(t.normalize(200), 1, accuracy: 1e-9)
        XCTAssertEqual(t.normalize(115), 0.5, accuracy: 1e-9)
        XCTAssertEqual(t.normalize(230), 1)          // range widens
        XCTAssertEqual(t.full, 230)
    }

    func testGameCubeRumbleDutyCycle() {
        var m = GameCubeRumble()
        let off = m.report(level: 0, counter: 5)
        XCTAssertEqual(Array(off[0...2]), [0x03, 0x55, 2], "stopped = brake")
        XCTAssertEqual(off.count, 64)
        let onFrames = (0..<100).filter { m.report(level: 0.3, counter: $0)[2] == 1 }.count
        XCTAssertEqual(onFrames, 30, accuracy: 2)
        XCTAssertEqual((0..<50).filter { m.report(level: 1, counter: $0)[2] == 1 }.count, 50)
    }

    func testSDLMappings() {
        let all = SDLMapping.allLines().split(separator: "\n")
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(all[0].hasPrefix(SDLMapping.macGUID))
        XCTAssertTrue(all[1].hasPrefix("030000007e0500006920000000000000,"))
        XCTAssertTrue(all[2].hasPrefix("030000007e0500007320000000000000,Nintendo GameCube Controller,"))
        // Every GameCube raw input used once; by-position and by-label layouts differ only in B and X.
        let gc = SDLMapping.gameCubeLine(layout: .positions)
        XCTAssertTrue(gc.contains("a:b1,b:b3,x:b0,y:b2"))
        XCTAssertTrue(SDLMapping.gameCubeLine(layout: .labels).contains("a:b1,b:b0,x:b3,y:b2"))
        let inputs = gc.split(separator: ",").compactMap { $0.split(separator: ":").last }.filter { $0.hasPrefix("b") }
        XCTAssertEqual(inputs.count, Set(inputs).count)
    }

    // MARK: DSU

    func testDSUMessageFraming() {
        let m = DSUServer.message(DSUServer.msgVersion, DSUServer.le16(1001) + [0, 0], serverID: 0x11223344)
        XCTAssertEqual(Array(m[0..<4]), Array("DSUS".utf8))
        XCTAssertEqual(DSUServer.u32(m, 12), 0x11223344)
        XCTAssertEqual(Int(m[6]) | Int(m[7]) << 8, m.count - 16)
        XCTAssertTrue(DSUServer.checkCRC(m))
        var bad = m; bad[20] ^= 1
        XCTAssertFalse(DSUServer.checkCRC(bad))
    }

    func testDSUPadDataLayout() {
        var p = DSUServer.Pad()
        p.hasMotion = true
        p.south = true; p.dpadLeft = true; p.options = true; p.home = true
        p.leftStick = SIMD2(1, -1)
        p.r2Analog = 0.5
        p.motion = MotionSample(timestampMicros: 0x0102, accel: SIMD3(0, 1, 0), gyro: SIMD3(10, 20, 30), temperatureC: 25)
        let d = DSUServer.padData(slot: 2, pad: p, number: 9)
        XCTAssertEqual(d.count, 80)                          // Dolphin's PadDataResponse minus header + type
        XCTAssertEqual(Array(d[0...3]), [2, 0x02, 0x02, 0x01])  // slot, connected, full gyro, USB
        XCTAssertEqual(d[11], 1)                             // active
        XCTAssertEqual(DSUServer.u32(d, 12), 9)
        XCTAssertEqual(d[16], 0x80 | 0x08)                   // D-left, Options
        XCTAssertEqual(d[17], 0x40)                          // Cross; R2 at half travel isn't "pressed" (> 0.5)
        XCTAssertEqual(d[18], 1)                             // PS / Home
        XCTAssertEqual(d[20], 255)                           // left X full right
        XCTAssertEqual(d[21], 0)                             // left Y full down (+y = up)
        XCTAssertEqual(d[24], 255)                           // D-left analog
        XCTAssertEqual(d[29], 255)                           // Cross analog
        XCTAssertEqual(d[34], 128)                           // R2 analog 0.5
        func f(_ o: Int) -> Float { Float(bitPattern: DSUServer.u32(d, o)) }
        XCTAssertEqual(DSUServer.u32(d, 48), 0x0102)         // timestamp (low word)
        XCTAssertEqual(f(56), 0); XCTAssertEqual(f(60), -1); XCTAssertEqual(f(64), 0)    // accel: sign flipped
        XCTAssertEqual(f(68), 10); XCTAssertEqual(f(72), -20); XCTAssertEqual(f(76), -30) // pitch, −yaw, −roll
    }

    func testDSUServerRoundTrip() throws {
        let server = DSUServer()
        let port: UInt16 = 36_760
        try server.start(port: port)
        defer { server.stop() }

        let s = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(s, 0)
        defer { close(s) }
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(s, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        func client(_ type: UInt32, _ payload: [UInt8]) -> [UInt8] {
            let body = DSUServer.le32(type) + payload
            var p = Array("DSUC".utf8) + DSUServer.le16(1001) + DSUServer.le16(UInt16(body.count)) + [0, 0, 0, 0] + DSUServer.le32(7) + body
            let crc = p.withUnsafeBufferPointer { UInt32(crc32(0, $0.baseAddress, uInt($0.count))) }
            p.replaceSubrange(8..<12, with: DSUServer.le32(crc))
            return p
        }
        func send(_ p: [UInt8]) {
            _ = p.withUnsafeBytes { b in
                withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(s, b.baseAddress, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
            }
        }
        func receive() -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: 256)
            let n = recv(s, &buf, buf.count, 0)
            return n > 0 ? Array(buf[0..<n]) : []
        }

        send(client(DSUServer.msgVersion, []))
        let v = receive()
        XCTAssertEqual(v.count, 24)                          // version + 2 padding bytes (Dolphin's VersionResponse)
        XCTAssertTrue(DSUServer.checkCRC(v))
        XCTAssertEqual(DSUServer.u32(v, 16), DSUServer.msgVersion)
        XCTAssertEqual(Int(v[20]) | Int(v[21]) << 8, 1001)

        var pad = DSUServer.Pad(); pad.north = true
        server.update(slot: 0, pad: pad)
        send(client(DSUServer.msgPorts, DSUServer.le32(2) + [0, 1]))
        let p0 = receive(), p1 = receive()
        XCTAssertEqual(p0.count, 32)
        XCTAssertEqual(Array(p0[20...21]), [0, 0x02])        // slot 0 connected
        XCTAssertEqual(Array(p1[20...21]), [1, 0x00])        // slot 1 empty

        send(client(DSUServer.msgPadData, [1, 0, 0, 0, 0, 0, 0, 0]))   // subscribe to slot 0
        Thread.sleep(forTimeInterval: 0.1)
        server.update(slot: 0, pad: pad)
        let d = receive()
        XCTAssertEqual(d.count, 100)
        XCTAssertTrue(DSUServer.checkCRC(d))
        XCTAssertEqual(DSUServer.u32(d, 16), DSUServer.msgPadData)
        XCTAssertEqual(d[20 + 17], 0x10)                     // triangle (north)
        server.update(slot: 1, pad: pad)                     // not subscribed: nothing sent
        XCTAssertTrue(receive().isEmpty)
    }

    // MARK: N64 mapping per SDL version

    func testN64MappingFollowsSDLVersion() throws {
        let sdl2 = try XCTUnwrap(N64Mapping.line(for: .libultraship))
        let sdl3 = try XCTUnwrap(N64Mapping.line(for: .libultraship, sdl3: true))
        XCTAssertTrue(sdl2.contains("dpup:b11") && sdl2.contains("misc1:b15"))
        // SDL3 / sdl2-compat: D-pad is hat 0 and Capture is b11 (as SDL3's own default mapping on hardware).
        XCTAssertTrue(sdl3.contains("dpup:h0.1,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,misc1:b11"))
        XCTAssertFalse(sdl3.contains("b12") || sdl3.contains("b15"))
        XCTAssertTrue(sdl3.hasPrefix(N64Mapping.sdl2GUID))
        XCTAssertNil(N64Mapping.line(for: .unknown, sdl3: true))
    }

    func testHelperVersionMarker() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("h.dylib")
        try Data([0xCF, 0xFA] + Array("xxNS2RUMBLE_VERSION=12\0yy".utf8)).write(to: f)
        XCTAssertEqual(GameInstaller.helperVersion(f), 12)
        try Data("no marker".utf8).write(to: f)
        XCTAssertEqual(GameInstaller.helperVersion(f), 0, "helpers from before the marker count as version 0")
    }

    // MARK: Controller-driver checks

    private func fakeGame(exe: String, sdl: String?) throws -> URL {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        for d in ["Contents/MacOS", "Contents/Frameworks"] {
            try FileManager.default.createDirectory(at: app.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        let macho: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE]
        try Data(macho + Array(exe.utf8)).write(to: app.appendingPathComponent("Contents/MacOS/Game"))
        if let sdl { try Data(macho + Array(sdl.utf8)).write(to: app.appendingPathComponent("Contents/Frameworks/libSDL2-2.0.0.dylib")) }
        return app
    }

    func testControllerDriverChecks() throws {
        let hostile = try fakeGame(exe: "SDL_JOYSTICK_HIDAPI\0", sdl: "SDL_JOYSTICK_HIDAPI_NINTENDO_CLASSIC\0")
        let harmless = try fakeGame(exe: "SDL_JOYSTICK_HIDAPI_PS4_RUMBLE\0", sdl: "SDL_JOYSTICK_HIDAPI_NINTENDO_CLASSIC\0")
        let oldSDL = try fakeGame(exe: "", sdl: "SDL_JOYSTICK_HIDAPI\0SDL_JOYSTICK_HIDAPI_PS4\0")
        defer { for u in [hostile, harmless, oldSDL] { try? FileManager.default.removeItem(at: u) } }
        func check(_ app: URL) -> GameAnalysis {
            var a = GameAnalysis(verdict: .noRumbleCalls)
            GameAnalyzer.checkControllerDrivers(app, exePath: app.appendingPathComponent("Contents/MacOS/Game").standardizedFileURL.path,
                                                staticSDL: false, into: &a)
            return a
        }
        XCTAssertEqual(check(hostile).changesControllerDrivers, true)
        XCTAssertEqual(check(hostile).n64DriverInSDL, true)
        XCTAssertEqual(check(harmless).changesControllerDrivers, false, "PS4/PS5 rumble hints don't touch the N64")
        XCTAssertEqual(check(oldSDL).n64DriverInSDL, false)
    }

    // MARK: Trigger test

    /// Measured on hardware: rest ≈ 33, click at ≈ 216, peak ≈ 220.
    private func pressTrigger(_ a: inout TriggerAnalyzer, rest: UInt8 = 33, click: UInt8 = 216, peak: UInt8 = 221, step: Int = 1) {
        for i in 0..<100 { a.addRest(rest &+ UInt8(i % 3)) }
        var v = Int(rest)
        while v < Int(peak) { a.addPress(UInt8(v), click: v >= Int(click)); v += step }
        while v > Int(rest) { a.addPress(UInt8(v), click: v >= Int(click)); v -= 4 }
    }

    func testTriggerAnalyzerPassesAGoodTrigger() {
        var a = TriggerAnalyzer(name: "L")
        pressTrigger(&a)
        let r = a.result()
        XCTAssertTrue(r.passed, "\(r.problems)")
        XCTAssertEqual(r.clickAt, 216)
        XCTAssertEqual(r.restNoise, 2)
        XCTAssertGreaterThan(r.distinctSteps, 150)
        XCTAssertEqual(r.range, TriggerRange(rest: 36, full: 216))       // median 34 + half the ±2 noise + 1
    }

    func testTriggerAnalyzerCatchesProblems() {
        var early = TriggerAnalyzer(name: "R")
        pressTrigger(&early, click: 90)                                  // clicks at a third of the travel
        XCTAssertTrue(early.result().problems.contains { $0.contains("click fires at") })

        var never = TriggerAnalyzer(name: "R")
        pressTrigger(&never, click: 255, peak: 200)
        XCTAssertTrue(never.result().problems.contains { $0.contains("never fired") })

        var quick = TriggerAnalyzer(name: "L")
        pressTrigger(&quick, step: 70)                                   // a fast press is not a fault
        let q = quick.result()
        XCTAssertTrue(q.passed, "\(q.problems)")
        XCTAssertTrue(q.notes.contains { $0.contains("Pressed quickly") })

        var deadSpot = TriggerAnalyzer(name: "L")                       // slow press with one big jump
        for _ in 0..<100 { deadSpot.addRest(33) }
        for v in stride(from: 33, through: 100, by: 1) { deadSpot.addPress(UInt8(v), click: false) }
        for v in stride(from: 180, through: 221, by: 1) { deadSpot.addPress(UInt8(v), click: v >= 216) }
        XCTAssertTrue(deadSpot.result().problems.contains { $0.contains("dead spot") })

        var wobbly = TriggerAnalyzer(name: "L")
        for i in 0..<100 { wobbly.addRest(UInt8(30 + (i % 12))) }
        XCTAssertTrue(wobbly.result().problems.contains { $0.contains("Wobbles") })
    }

    func testFixedTriggerCalibration() {
        var t = TriggerCal(range: TriggerRange(rest: 35, full: 216))
        XCTAssertEqual(t.normalize(20), 0)                      // below rest: no underflow, reads 0
        XCTAssertEqual(t.normalize(216), 1)
        XCTAssertEqual(t.normalize(221), 1)
        XCTAssertEqual(t.normalize(125), 0.497, accuracy: 0.01)
        XCTAssertEqual(t.full, 216, "a calibrated range doesn't widen")
    }

    /// Replays a real GameCube capture over USB (every button once, triggers pressed slowly, sticks rolled;
    /// input reports only) through the analyzer.
    func testTriggerAnalyzerOnRealCapture() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("research/captures/gamecube-usb-buttons.ns2cap")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("fixture missing") }
        let reports = try CaptureWriter.read(url: url).map(\.bytes).compactMap { GCState(report: $0) }
        var l = TriggerAnalyzer(name: "L"), r = TriggerAnalyzer(name: "R")
        for s in reports.prefix(500) { l.addRest(s.leftTrigger); r.addRest(s.rightTrigger) }
        for s in reports.dropFirst(500) {
            l.addPress(s.leftTrigger, click: s.buttons.contains(.l))
            r.addPress(s.rightTrigger, click: s.buttons.contains(.r))
        }
        for res in [l.result(), r.result()] {
            print("fixture \(res.name): rest \(res.rest) ±\(res.restNoise) click \(res.clickAt.map(String.init) ?? "-") peak \(res.peak) positions \(res.distinctSteps) jump \(res.biggestJump) problems \(res.problems)")
            XCTAssertNotNil(res.clickAt)
            XCTAssertGreaterThan(Int(res.clickAt ?? 0), 200)
        }
    }

    // MARK: Game stick calibration

    func testGameStickCalibrationMatchesSDL() {
        // GameCube main stick as measured: x 787…3242. SDL (BattleShip) reported −20157…19003 for it.
        let x = AxisCal(min: 787, center: 1993, max: 3242), y = AxisCal(min: 834, center: 2111, max: 3314)
        let v = GameStickCalibration.envValue([StickCalibration(x: x, y: y, deadzone: 0.06)])
            .split(separator: ",").map { Int($0)! }
        XCTAssertEqual(v.count, 12)
        XCTAssertEqual(v[0], -873, accuracy: 2)                     // center
        XCTAssertEqual(v[0] - v[1], -20173, accuracy: 30)           // full left ≈ what SDL reported (−20157)
        XCTAssertEqual(v[0] + v[2], 19116, accuracy: 30)            // full right ≈ 19003
        XCTAssertEqual(v[3], -(2111 * 65535 / 4095 - 32768), accuracy: 2)   // Y inverted
        XCTAssertEqual(Array(v[6...]), [0, 32768, 32767, 0, 32768, 32767], "no second stick: unscaled")
        XCTAssertEqual(GameStickCalibration.envKey(productID: 0x2073), "NS2_STICKCAL_2073")
    }

    // MARK: Rumble routing and DSU slots

    func testRumbleRouting() {
        let routes = [RumbleRoute(productID: 0x2019, player: 2, deviceID: 500, item: "N64 #2 (P2)"),
                      RumbleRoute(productID: 0x2019, player: 1, deviceID: 900, item: "N64 #1 (P1)"),
                      RumbleRoute(productID: 0x2073, player: 3, deviceID: 700, item: "GC (P3)")]
        XCTAssertEqual(RumbleRoute.choose(routes, productID: 0x2019, deviceID: 500, rank: -1), "N64 #2 (P2)", "exact device")
        XCTAssertEqual(RumbleRoute.choose(routes, productID: 0x2019, deviceID: 0, rank: 0), "N64 #2 (P2)", "rank 0 = connected first")
        XCTAssertEqual(RumbleRoute.choose(routes, productID: 0x2019, deviceID: 0, rank: 1), "N64 #1 (P1)")
        XCTAssertEqual(RumbleRoute.choose(routes, productID: 0x2019, deviceID: 0, rank: -1), "N64 #1 (P1)", "unknown: lowest player")
        XCTAssertEqual(RumbleRoute.choose(routes, productID: 0x2073, deviceID: 0, rank: 0), "GC (P3)", "only one: rank not needed")
        XCTAssertEqual(RumbleRoute.choose(routes, productID: 0x2019, deviceID: 12345, rank: -1), "N64 #1 (P1)", "stale device id falls back")
        XCTAssertNil(RumbleRoute.choose(routes, productID: 0x2069, deviceID: 0, rank: -1))
    }

    func testDSUSlots() {
        XCTAssertEqual(DSUServer.slots(forPlayers: [1, 2]), [1: 0, 2: 1])
        XCTAssertEqual(DSUServer.slots(forPlayers: [1, 5]), [1: 0, 5: 1], "player 5 takes the first free slot")
        XCTAssertEqual(DSUServer.slots(forPlayers: [1, 2, 3, 4, 5]), [1: 0, 2: 1, 3: 2, 4: 3], "no slot left")
        XCTAssertEqual(DSUServer.slots(forPlayers: [6, 5, 2]), [2: 1, 5: 0, 6: 2])
    }

    // MARK: Per-controller profiles

    func testDeviceProfiles() throws {
        var store = ProfileStore()
        var def = store.activeProfile(for: .gameCube)
        def.hapticsIntensity = 0.4
        store.update(def)
        XCTAssertTrue(store.ensureDeviceProfile(device: "gameCube-AAAA", kind: .gameCube, tag: "#AAAA"))
        XCTAssertFalse(store.ensureDeviceProfile(device: "gameCube-AAAA", kind: .gameCube, tag: "#AAAA"), "only once")
        let own = store.profile(for: .gameCube, device: "gameCube-AAAA")
        XCTAssertEqual(own.name, "GameCube #AAAA")
        XCTAssertEqual(own.hapticsIntensity, 0.4, "copied from the default")
        XCTAssertNotEqual(own.id, def.id)
        // Its calibration is its own
        var changed = own; changed.hapticsIntensity = 0.9; store.update(changed)
        XCTAssertEqual(store.profile(for: .gameCube, device: "gameCube-AAAA").hapticsIntensity, 0.9)
        XCTAssertEqual(store.profile(for: .gameCube, device: "gameCube-BBBB").hapticsIntensity, 0.4, "unknown controller: default")
        XCTAssertEqual(store.profile(for: .gameCube, device: nil).id, def.id)
        // Reassign, delete
        store.assign(def.id, to: "gameCube-AAAA")
        XCTAssertEqual(store.profile(for: .gameCube, device: "gameCube-AAAA").id, def.id)
        store.assign(changed.id, to: "gameCube-AAAA")
        store.delete(changed.id)
        XCTAssertEqual(store.profile(for: .gameCube, device: "gameCube-AAAA").id, def.id, "deleted profile: back to default")
        // Stores saved by 1.0 (no "assigned") still decode
        let old = try JSONEncoder().encode(ProfileStore())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        json.removeValue(forKey: "assigned")
        XCTAssertNoThrow(try JSONDecoder().decode(ProfileStore.self, from: JSONSerialization.data(withJSONObject: json)))
    }

    func testSerialFromFlashReply() {
        var r = [UInt8](repeating: 0, count: 0x50)
        r.replaceSubrange(0x12..<0x1F, with: Array("TEST123456789".utf8))
        XCTAssertEqual(NS2Command.serial(fromFlashReply: r), "TEST123456789")
        XCTAssertNil(NS2Command.serial(fromFlashReply: [UInt8](repeating: 0, count: 0x50)), "blank flash")
        XCTAssertNil(NS2Command.serial(fromFlashReply: [0x02, 0x01]), "short reply")
        XCTAssertEqual(NS2Command.flashRead(address: 0x13000).suffix(4), [0x00, 0x30, 0x01, 0x00])
    }

    // MARK: Orientation filter

    /// Simulates a controller rotating at a constant rate about a device axis, with matching accelerometer
    /// readings (gravity seen from the controller), at 250 samples per second.
    private func simulate(_ f: inout OrientationFilter, degPerSec rate: SIMD3<Double>, seconds: Double, start: UInt64 = 1_000) -> UInt64 {
        var truth = f.orientation
        var t = start
        let dt = 0.004
        for _ in 0..<Int(seconds / dt) {
            let w = rate * (.pi / 180)
            let dq = truth * simd_quatd(ix: w.x, iy: w.y, iz: w.z, r: 0)
            truth = simd_normalize(simd_quatd(vector: truth.vector + dq.vector * (0.5 * dt)))
            t += 4_000
            let accel = truth.inverse.act(SIMD3<Double>(0, 1, 0))
            f.update(MotionSample(timestampMicros: t, accel: accel, gyro: rate, temperatureC: 25))
        }
        return t
    }

    func testOrientationFilterTracksTilt() {
        var f = OrientationFilter()
        var t = simulate(&f, degPerSec: .zero, seconds: 0.5)
        XCTAssertEqual(f.tilt.pitch, 0, accuracy: 0.5); XCTAssertEqual(f.tilt.roll, 0, accuracy: 0.5)

        t = simulate(&f, degPerSec: SIMD3(45, 0, 0), seconds: 1, start: t)      // top edge up (positive gyro X)
        XCTAssertEqual(f.tilt.pitch, 45, accuracy: 2)
        XCTAssertEqual(f.tilt.roll, 0, accuracy: 2)

        var g = OrientationFilter()
        t = simulate(&g, degPerSec: .zero, seconds: 0.2)
        _ = simulate(&g, degPerSec: SIMD3(0, 0, -30), seconds: 1, start: t)       // right grip down
        XCTAssertEqual(g.tilt.roll, 30, accuracy: 2)
    }

    func testOrientationFilterStartsLevelFromAccelerometer() {
        var f = OrientationFilter()
        // Resting on its grips, tipped ~11° (as measured on hardware): accel (0, 0.98, 0.19)
        let a = simd_normalize(SIMD3<Double>(0, 0.98, 0.19))
        for i in 0..<50 { f.update(MotionSample(timestampMicros: UInt64(1_000 + i * 4_000), accel: a, gyro: .zero, temperatureC: 25)) }
        XCTAssertEqual(f.tilt.pitch, -11, accuracy: 1, "face tipped away from the player")
    }

    func testOrientationFilterCorrectsGyroDrift() {
        var f = OrientationFilter()
        // Still and flat, but the gyro reports a 2 °/s offset: the accelerometer keeps the tilt near zero.
        for i in 0..<2500 {
            f.update(MotionSample(timestampMicros: UInt64(1_000 + i * 4_000), accel: SIMD3(0, 1, 0), gyro: SIMD3(2, 0, 0), temperatureC: 25))
        }
        XCTAssertLessThan(abs(f.tilt.pitch), 2, "10 s of a 2 °/s offset would otherwise be 20°")
    }
}
