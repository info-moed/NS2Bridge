import Foundation

/// Named settings for one kind of controller: stick calibration + deadzones and vibration.
public struct ControllerProfile: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ControllerKind
    public var sticks: [StickCalibration]
    public var hapticsEnabled: Bool
    public var hapticsIntensity: Double
    /// Analog trigger ranges from the trigger test (GameCube: L, R). nil = learn automatically.
    public var triggers: [TriggerRange]?

    public init(name: String, kind: ControllerKind, id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.sticks = Array(repeating: kind.defaultCalibration, count: kind.stickNames.count)
        self.hapticsEnabled = true
        self.hapticsIntensity = 1.0
    }

    public func calibration(_ stick: Int) -> StickCalibration {
        stick < sticks.count ? sticks[stick] : kind.defaultCalibration
    }

    public mutating func setCalibration(_ c: StickCalibration, stick: Int) {
        while sticks.count <= stick { sticks.append(kind.defaultCalibration) }
        sticks[stick] = c
    }
}

/// All profiles, which one is the default for each controller kind, and which profile each physical
/// controller uses. A controller with a stable identity (see `ConnectedController.deviceKey`) gets its own
/// profile the first time it connects, copied from its kind's default, and keeps it on every reconnect.
public struct ProfileStore: Codable, Equatable, Sendable {
    public var profiles: [ControllerProfile] = []
    /// ControllerKind.rawValue → default profile id (used for new controllers and ones without an identity).
    public var active: [String: UUID] = [:]
    /// Physical controller (`deviceKey`) → its profile id. Optional so older stores still decode.
    public var assigned: [String: UUID]?

    public init() { ensureDefaults() }

    /// Every kind always has at least a "Default" profile, and an active one.
    public mutating func ensureDefaults() {
        // GameCube profiles made before its own default existed got the Pro's stick ranges: upgrade untouched ones.
        for i in profiles.indices where profiles[i].kind == .gameCube && profiles[i].sticks.allSatisfy({ $0 == .default }) {
            profiles[i].sticks = profiles[i].sticks.map { _ in ControllerKind.gameCube.defaultCalibration }
        }
        for kind in ControllerKind.allCases {
            if !profiles.contains(where: { $0.kind == kind }) {
                profiles.append(ControllerProfile(name: "Default", kind: kind))
            }
            if let id = active[kind.rawValue], profiles.contains(where: { $0.id == id }) { continue }
            active[kind.rawValue] = profiles.first { $0.kind == kind }!.id
        }
    }

    public func profiles(for kind: ControllerKind) -> [ControllerProfile] { profiles.filter { $0.kind == kind } }

    /// The profile a controller uses: its own if it has one, else its kind's default.
    public func profile(for kind: ControllerKind, device: String?) -> ControllerProfile {
        if let device, let id = assigned?[device], let p = profiles.first(where: { $0.id == id && $0.kind == kind }) { return p }
        return activeProfile(for: kind)
    }

    /// First connection of a controller with an identity: give it its own profile, a copy of its kind's
    /// default, named e.g. "GameCube #3F2A". Returns true when one was created.
    @discardableResult
    public mutating func ensureDeviceProfile(device: String, kind: ControllerKind, tag: String) -> Bool {
        if let id = assigned?[device], profiles.contains(where: { $0.id == id }) { return false }
        var p = activeProfile(for: kind)
        p.id = UUID()
        p.name = "\(kind.shortName) \(tag)"
        profiles.append(p)
        assigned = (assigned ?? [:]).merging([device: p.id]) { $1 }
        return true
    }

    /// Point a controller at another profile of its kind.
    public mutating func assign(_ profileID: UUID, to device: String) {
        guard profiles.contains(where: { $0.id == profileID }) else { return }
        assigned = (assigned ?? [:]).merging([device: profileID]) { $1 }
    }

    /// Controllers using a profile (their device keys).
    public func devices(using profileID: UUID) -> [String] {
        (assigned ?? [:]).filter { $0.value == profileID }.map(\.key)
    }

    public func activeProfile(for kind: ControllerKind) -> ControllerProfile {
        let id = active[kind.rawValue]
        return profiles.first { $0.id == id } ?? profiles.first { $0.kind == kind } ?? ControllerProfile(name: "Default", kind: kind)
    }

    public mutating func setActive(_ id: UUID) {
        guard let p = profiles.first(where: { $0.id == id }) else { return }
        active[p.kind.rawValue] = id
    }

    public mutating func update(_ p: ControllerProfile) {
        if let i = profiles.firstIndex(where: { $0.id == p.id }) { profiles[i] = p }
    }

    /// New profile for a kind, copying the currently active one's settings. Becomes active.
    @discardableResult
    public mutating func add(name: String, kind: ControllerKind) -> ControllerProfile {
        var p = activeProfile(for: kind)
        p.id = UUID()
        p.name = name
        profiles.append(p)
        active[kind.rawValue] = p.id
        return p
    }

    /// Deletes a profile; a kind's last profile can't be deleted.
    public mutating func delete(_ id: UUID) {
        guard let p = profiles.first(where: { $0.id == id }), profiles(for: p.kind).count > 1 else { return }
        profiles.removeAll { $0.id == id }
        assigned = assigned?.filter { $0.value != id }      // those controllers fall back to the default
        ensureDefaults()
    }
}
