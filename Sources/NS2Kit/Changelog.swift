import Foundation

public enum Changelog {
    /// The `## <version>` (or `## [<version>] - <date>`) section of a Keep-a-Changelog file, without its heading.
    public static func section(_ text: String, version: String) -> String? {
        var lines: [Substring] = [], inside = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                if inside { break }
                let title = line.dropFirst(3).trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
                inside = title == version || title.hasPrefix(version + "]") || title.hasPrefix(version + " ")
                continue
            }
            if inside { lines.append(line) }
        }
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? nil : body
    }
}
