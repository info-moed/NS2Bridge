import Foundation

/// A single-cell lithium battery reading from a controller.
public struct BatteryReading: Codable, Sendable, Equatable {
    public var millivolts: Int?          // measured cell voltage, if the controller reports it
    public var level: Double             // controller's own coarse level 0…1 (Pro 2: 10 steps, N64: 5 steps)
    public var charging: Bool
    public var externalPower: Bool
    public var statusRaw: [UInt8]        // raw charge-status bytes (Switch 2 command 0x0B/0x04), for the curious

    public init(millivolts: Int?, level: Double, charging: Bool, externalPower: Bool, statusRaw: [UInt8] = []) {
        self.millivolts = millivolts; self.level = level; self.charging = charging
        self.externalPower = externalPower; self.statusRaw = statusRaw
    }

    /// Plugged in and no longer charging.
    public var isFull: Bool { externalPower && !charging && level >= 0.99 }
}

/// Voltage → state-of-charge curve. Default is a typical single-cell LiPo discharge curve at light load;
/// a calibration run replaces it with one measured on the user's own controller.
public struct BatteryCurve: Codable, Sendable, Equatable {
    /// (millivolts, percent 0…100), sorted by voltage ascending.
    public var points: [[Double]]
    public var measured: Bool

    public static let typicalLiPo = BatteryCurve(points: [
        [3270, 0], [3610, 5], [3690, 10], [3710, 15], [3730, 20], [3750, 25], [3770, 30], [3790, 35],
        [3800, 40], [3820, 45], [3840, 50], [3850, 55], [3870, 60], [3910, 65], [3950, 70], [3980, 75],
        [4020, 80], [4080, 85], [4110, 90], [4150, 95], [4200, 100],
    ], measured: false)

    public init(points: [[Double]], measured: Bool) { self.points = points; self.measured = measured }

    /// Percent 0…100 for a voltage (linear between points, clamped).
    public func percent(millivolts mv: Int) -> Double {
        let v = Double(mv)
        guard let first = points.first, let last = points.last else { return 0 }
        if v <= first[0] { return first[1] }
        if v >= last[0] { return last[1] }
        for i in 1..<points.count where v <= points[i][0] {
            let a = points[i - 1], b = points[i]
            let t = (v - a[0]) / max(1, b[0] - a[0])
            return a[1] + t * (b[1] - a[1])
        }
        return last[1]
    }
}

/// One stored history point (about one per minute).
public struct BatterySample: Codable, Sendable, Equatable {
    public var t: Date
    public var mv: Int?
    public var level: Double
    public var charging: Bool
    public var external: Bool
}

/// Everything NS2 Bridge has learned about one physical controller's battery.
public struct BatteryRecord: Codable, Sendable, Equatable {
    public var key: String
    public var kind: ControllerKind
    public var firstSeen: Date
    public var samples: [BatterySample] = []
    /// Charge throughput seen while charging, in "full batteries" (100 % added = 1 cycle).
    public var cycles: Double = 0
    public var chargingSeconds: Double = 0
    public var batterySeconds: Double = 0
    public var maxMillivolts: Int?
    public var minMillivolts: Int?
    public var lastFull: Date?
    public var curve: BatteryCurve = .typicalLiPo
    public var calibration: CalibrationRun?
    public var lifeTests: [LifeTestResult] = []

    public init(key: String, kind: ControllerKind, now: Date = Date()) {
        self.key = key; self.kind = kind; self.firstSeen = now
    }

    public static let maxSamples = 20_000   // ~2 weeks at one per minute

    /// State of charge 0…100 for a reading: from voltage when available, else the coarse level.
    public func percent(_ r: BatteryReading) -> Double {
        if let mv = r.millivolts { return curve.percent(millivolts: mv) }
        return r.level * 100
    }

    /// Fold a new reading into the record. Call about every 10 s; stores at most one sample per minute.
    public mutating func add(_ r: BatteryReading, at now: Date = Date()) {
        if let mv = r.millivolts {
            maxMillivolts = max(maxMillivolts ?? mv, mv)
            minMillivolts = min(minMillivolts ?? mv, mv)
        }
        if r.isFull { lastFull = now }
        if let last = samples.last {
            let dt = now.timeIntervalSince(last.t)
            if dt > 0, dt < 600 {                         // ignore gaps (controller was away)
                if r.charging { chargingSeconds += dt } else if !r.externalPower { batterySeconds += dt }
                // Cycle counting: charge added while charging, from the voltage curve when possible.
                if r.charging, last.charging {
                    let before = last.mv.map { curve.percent(millivolts: $0) } ?? last.level * 100
                    let after = percent(r)
                    if after > before { cycles += (after - before) / 100 }
                }
            }
            guard dt >= 60 || r.charging != last.charging || r.externalPower != last.external else { return }
        }
        samples.append(BatterySample(t: now, mv: r.millivolts, level: r.level, charging: r.charging, external: r.externalPower))
        if samples.count > Self.maxSamples { samples.removeFirst(samples.count - Self.maxSamples) }
    }

    /// Rate of change in percent per hour over the recent window (least squares), if the trend is usable.
    public func ratePerHour(window: TimeInterval = 20 * 60, now: Date = Date()) -> Double? {
        let recent = samples.filter { now.timeIntervalSince($0.t) <= window }
        guard recent.count >= 4, let first = recent.first, let last = recent.last,
              last.t.timeIntervalSince(first.t) >= 5 * 60,
              recent.allSatisfy({ $0.charging == last.charging }) else { return nil }
        let xs = recent.map { $0.t.timeIntervalSince(first.t) / 3600 }
        let ys = recent.map { s in s.mv.map { curve.percent(millivolts: $0) } ?? s.level * 100 }
        let n = Double(xs.count), mx = xs.reduce(0, +) / n, my = ys.reduce(0, +) / n
        let num = zip(xs, ys).map { ($0 - mx) * ($1 - my) }.reduce(0, +)
        let den = xs.map { ($0 - mx) * ($0 - mx) }.reduce(0, +)
        return den > 0 ? num / den : nil
    }
}

// MARK: - Calibration (full discharge → personal voltage curve)

/// Charge to full, then run on battery until low. Assuming a roughly steady load, the fraction of
/// time remaining at each moment is the fraction of charge remaining — which maps voltage to percent.
public struct CalibrationRun: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable { case waitingForFull, discharging, done }
    public var stage: Stage = .waitingForFull
    public var started = Date()
    public var dischargeStart: Date?
    /// (seconds since discharge start, millivolts)
    public var points: [[Double]] = []

    public init() {}

    public mutating func add(_ r: BatteryReading, at now: Date = Date()) {
        switch stage {
        case .waitingForFull:
            if r.isFull { stage = .discharging; dischargeStart = nil; points = [] }
        case .discharging:
            guard !r.charging, !r.externalPower, let mv = r.millivolts else { return }   // only true discharge
            if dischargeStart == nil { dischargeStart = now }
            points.append([now.timeIntervalSince(dischargeStart!), Double(mv)])
            if mv <= 3450 || r.level <= 0.1 { stage = .done }                              // low enough
        case .done:
            break
        }
    }

    public var dischargeMinutes: Double { (points.last?[0] ?? 0) / 60 }

    /// Builds the curve. If the run stopped before empty, the remaining tail is extrapolated from the
    /// typical LiPo curve for the last measured voltage.
    public func curve() -> BatteryCurve? {
        guard points.count >= 10, let last = points.last, last[0] > 600 else { return nil }
        let endPct = BatteryCurve.typicalLiPo.percent(millivolts: Int(last[1]))   // charge still left at the end
        let total = last[0] / max(0.05, 1 - endPct / 100)                          // projected full-to-empty time
        var pairs = points.map { [$0[1], 100 * (1 - $0[0] / total)] }              // (mV, %)
        pairs.append([4200, 100])
        pairs.append([3270, 0])
        pairs.sort { $0[0] < $1[0] }
        // Enforce monotonic percent vs voltage, then thin to ~25 points.
        var mono: [[Double]] = []
        for p in pairs {
            if let l = mono.last, p[1] < l[1] { continue }
            if let l = mono.last, p[0] == l[0] { mono[mono.count - 1] = p; continue }
            mono.append(p)
        }
        let step = max(1, mono.count / 25)
        var thin = stride(from: 0, to: mono.count, by: step).map { mono[$0] }
        if thin.last != mono.last, let m = mono.last { thin.append(m) }
        return BatteryCurve(points: thin, measured: true)
    }
}

// MARK: - Battery life test

public struct LifeTestResult: Codable, Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var date: Date
    public var minutes: Double
    public var drainPerHour: Double        // percent per hour
    public var withRumble: Bool
    public var projectedHoursFull: Double  // 100 % / drain

    public init(date: Date, minutes: Double, drainPerHour: Double, withRumble: Bool, projectedHoursFull: Double) {
        self.date = date; self.minutes = minutes; self.drainPerHour = drainPerHour
        self.withRumble = withRumble; self.projectedHoursFull = projectedHoursFull
    }
}
