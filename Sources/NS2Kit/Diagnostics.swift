import Foundation
import OSLog

/// The privacy-scrubbed diagnostics report people attach to bug reports (Diagnostics tab → Export Diagnostics
/// Report…). Nothing is sent anywhere: the report is shown, then saved or copied by the user.
public enum Diagnostics {
    /// Removes personal data from report text: the home folder becomes `~`, any other user's home folder
    /// `/Users/…`, Bluetooth addresses keep only their first half, controller serial numbers and email addresses
    /// are replaced.
    public static func scrub(_ text: String, home: String = NSHomeDirectory()) -> String {
        var s = text
        if !home.isEmpty, home != "/" { s = s.replacingOccurrences(of: home, with: "~") }
        let rules: [(String, String)] = [
            (#"/Users/[A-Za-z0-9._-]+/"#, "/Users/…/"),
            (#"\b([0-9A-Fa-f]{2}[:-][0-9A-Fa-f]{2}[:-][0-9A-Fa-f]{2})[:-][0-9A-Fa-f]{2}[:-][0-9A-Fa-f]{2}[:-][0-9A-Fa-f]{2}\b"#, "$1:••:••:••"),
            (#"\bH[A-Z]{2}[0-9]{11}\b"#, "[serial]"),
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "[email]"),
        ]
        for (pattern, template) in rules {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return s
    }

    /// This app's own log entries (subsystem `local.ns2bridge`) from the last `minutes`, oldest first.
    public static func recentLog(minutes: Double = 15, limit: Int = 400) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return ["(log unavailable)"] }
        let since = store.position(date: Date().addingTimeInterval(-minutes * 60))
        let predicate = NSPredicate(format: "subsystem == %@", "local.ns2bridge")
        guard let entries = try? store.getEntries(at: since, matching: predicate) else { return ["(log unavailable)"] }
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss.SSS"
        let lines = entries.compactMap { $0 as? OSLogEntryLog }
            .map { "\(time.string(from: $0.date)) [\($0.category)] \($0.composedMessage)" }
        return Array(lines.suffix(limit))
    }

    /// The Mac's model identifier (e.g. `Mac15,12`).
    public static var macModel: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }
}
