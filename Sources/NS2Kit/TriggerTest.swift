import Foundation

/// A trigger's usable travel: raw value at rest and at full press (100%).
public struct TriggerRange: Codable, Equatable, Sendable {
    public var rest: UInt8
    public var full: UInt8
    public init(rest: UInt8, full: UInt8) { self.rest = rest; self.full = full }
}

/// What one analog trigger did during the trigger test.
public struct TriggerTestResult: Codable, Equatable, Sendable {
    public var name: String
    public var rest: UInt8              // median raw value, untouched
    public var restNoise: Int           // max − min while untouched
    public var peak: UInt8              // highest raw value reached
    public var clickAt: UInt8?          // raw value when the full-press click bit first set (nil = never)
    public var distinctSteps: Int       // different raw values seen on the way down (resolution)
    public var biggestJump: Int         // largest change between two reports (4 ms apart) while pressing
    public var ghostClick: Bool         // click bit set with the trigger barely moved
    public var problems: [String]       // real faults: the test fails
    public var notes: [String] = []     // things worth knowing that don't fail it (e.g. pressed quickly)

    public var passed: Bool { problems.isEmpty }
    /// Travel to save: from just above the resting noise to the click (a full press reads 100%).
    public var range: TriggerRange {
        TriggerRange(rest: UInt8(min(255, Int(rest) + restNoise / 2 + 1)), full: clickAt ?? peak)
    }
}

/// Collects one trigger's samples during the test and judges them.
///
/// Fails only on real faults (NSO GameCube measured on hardware: rest ≈ 33, click ≈ 216, peak ≈ 220):
/// - untouched noise > 6 raw units (the trigger wobbles at rest, reads as a light press)
/// - usable travel < 120 raw units
/// - the full-press click never fires, fires early (< 70% of travel), or fires with the trigger barely moved
/// - a jump > 60 raw units between two reports (4 ms) *during a slow press*: a dead spot or a bad sensor
/// How fast someone presses isn't a fault: a quick press (few distinct positions, or a big jump while
/// the rise from rest to the click took under 160 ms) only adds a note suggesting a slower press.
public struct TriggerAnalyzer: Sendable {
    public let name: String
    private var restValues: [UInt8] = []
    private var last: UInt8?
    private var seen = Set<UInt8>()
    private var peak: UInt8 = 0
    private var clickAt: UInt8?
    private var biggestJump = 0
    private var ghost = false
    private var samples = 0
    private var riseStart: Int?         // report index where the trigger left rest
    private var riseEnd: Int?           // report index of the click (or of the peak, if it never clicked)

    public init(name: String) { self.name = name }

    /// Reports (4 ms each) from leaving rest to the click: how slowly the trigger was pressed.
    public var riseReports: Int { (riseEnd ?? samples) - (riseStart ?? samples) }

    public var hasRest: Bool { restValues.count >= 50 }
    public var restMedian: UInt8 {
        let s = restValues.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }
    public var clicked: Bool { clickAt != nil }
    public var peakValue: UInt8 { peak }

    public mutating func addRest(_ v: UInt8) { restValues.append(v) }

    public mutating func addPress(_ v: UInt8, click: Bool) {
        if let last { biggestJump = max(biggestJump, abs(Int(v) - Int(last))) }
        last = v
        seen.insert(v)
        if riseStart == nil, Int(v) > Int(restMedian) + 10 { riseStart = samples }
        if v > peak, clickAt == nil { riseEnd = samples }
        peak = max(peak, v)
        if click, clickAt == nil {
            clickAt = v
            riseEnd = samples
            if Int(v) < Int(restMedian) + 40 { ghost = true }
        }
        samples += 1
    }

    public func result() -> TriggerTestResult {
        let rest = restMedian
        let noise = Int(restValues.max() ?? 0) - Int(restValues.min() ?? 0)
        let travel = Int(peak) - Int(rest)
        let steps = seen.filter { Int($0) > Int(rest) + noise && $0 <= (clickAt ?? peak) }.count
        var p: [String] = []
        if noise > 6 { p.append("Wobbles by \(noise) at rest (≤ 6 expected): may read as a light press.") }
        if travel < 120 { p.append("Only \(max(0, travel)) units of travel (≥ 120 expected): press all the way.") }
        if let c = clickAt {
            if ghost { p.append("The full-press click fired with the trigger barely pressed.") }
            else if travel > 0, Double(Int(c) - Int(rest)) / Double(travel) < 0.7 {
                p.append("The click fires at \(Int(Double(Int(c) - Int(rest)) / Double(travel) * 100))% of travel (≥ 70% expected).")
            }
        } else {
            p.append("The full-press click never fired: press until it clicks.")
        }
        var notes: [String] = []
        let slowPress = riseReports >= 40            // ≥ 160 ms from rest to the click
        if biggestJump > 60 {
            if slowPress { p.append("Jumped \(biggestJump) units between two readings during a slow press: possibly a dead spot.") }
            else { notes.append("Pressed quickly (jumps of up to \(biggestJump) units). For a finer check, press more slowly.") }
        }
        if steps < 60, travel >= 120, !notes.contains(where: { $0.hasPrefix("Pressed quickly") }) {
            notes.append("\(steps) distinct positions seen. Pressing more slowly shows the travel in finer detail.")
        }
        var r = TriggerTestResult(name: name, rest: rest, restNoise: noise, peak: peak, clickAt: clickAt,
                                  distinctSteps: steps, biggestJump: biggestJump, ghostClick: ghost, problems: p)
        r.notes = notes
        return r
    }
}
