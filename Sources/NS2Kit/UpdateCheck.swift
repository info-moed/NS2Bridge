import Foundation

/// Checks GitHub for a newer release: one HTTPS request to GitHub's public Releases API, sending nothing but the
/// request itself. Only when the user asks, or once a day if they turned automatic checks on (Setup).
public enum UpdateCheck {
    public struct Release: Equatable, Sendable {
        public var version: String          // "1.2.0"
        public var page: URL                // the release page
        public var notes: String            // release notes (Markdown)
        public var download: URL?           // the versioned zip, if present
    }

    public static let latestURL = URL(string: "https://api.github.com/repos/info-moed/NS2Bridge/releases/latest")!

    /// Numeric comparison of dotted versions ("1.10.0" > "1.9.2"); a leading "v" is ignored.
    public static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ v: String) -> [Int] {
            v.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let r = parts(remote), l = parts(local)
        for i in 0..<max(r.count, l.count) {
            let a = i < r.count ? r[i] : 0, b = i < l.count ? l[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// The latest release from GitHub's JSON (`tag_name`, `html_url`, `body`, `assets`).
    public static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { ($0["name"] as? String) == "NS2Bridge-\(version)-macOS.zip" }
        return Release(version: version, page: page, notes: json["body"] as? String ?? "",
                       download: (zip?["browser_download_url"] as? String).flatMap(URL.init(string:)))
    }

    public static func fetchLatest() async throws -> Release? {
        var request = URLRequest(url: latestURL, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }
}
