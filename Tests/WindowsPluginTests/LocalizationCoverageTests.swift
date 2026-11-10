import Foundation
import Testing

/// QA D4: "7 układów · No workspace uses Strefy". A string that the code builds with interpolation (`String(localized:
/// "No workspace uses \(name)")`) has a key the catalog must carry as `%@`/`%lld`; renaming a literal key to an
/// interpolated one left it without a Polish value. This reads every localized literal of the plugin's sources and
/// checks that the catalog has a key that matches it with a Polish translation.
@Suite(.timeLimit(.minutes(1))) struct LocalizationCoverageTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private struct Entry {
        var key: String
        var hasPolish: Bool
    }

    private func catalog() throws -> [Entry] {
        let data = try Data(contentsOf: Self.root.appending(path: "Resources/Localizable.xcstrings"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(object["strings"] as? [String: Any])
        return strings.map { key, value in
            let localizations = (value as? [String: Any])?["localizations"] as? [String: Any]
            return Entry(key: key, hasPolish: localizations?["pl"] != nil)
        }
    }

    /// The literals of `String(localized: "…")` and `Text("…")` (not `verbatim:`) in a source file.
    private func literals(in text: String) -> [String] {
        let pattern = #"(?:String\(localized: |\bText\()"((?:[^"\\]|\\.)*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// A pattern that the catalog key of a literal matches: each interpolation becomes a format specifier.
    private func matcher(for literal: String) -> NSRegularExpression? {
        var pattern = ""
        var rest = Substring(literal)
        while let start = rest.range(of: "\\(") {
            pattern += NSRegularExpression.escapedPattern(for: String(rest[..<start.lowerBound]))
            // Skip the balanced interpolation.
            var depth = 1
            var index = start.upperBound
            while index < rest.endIndex, depth > 0 {
                if rest[index] == "(" { depth += 1 }
                if rest[index] == ")" { depth -= 1 }
                index = rest.index(after: index)
            }
            pattern += "%(?:@|lld|d|f|ld|llu)"
            rest = rest[index...]
        }
        pattern += NSRegularExpression.escapedPattern(for: String(rest))
        return try? NSRegularExpression(pattern: "^" + pattern + "$")
    }

    @Test func everyLocalizedLiteralOfThePluginHasAPolishCatalogKey() throws {
        let entries = try catalog()
        let sources = Self.root.appending(path: "Sources/WindowsPlugin")
        let files =
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var missing: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for literal in literals(in: text) where !literal.isEmpty {
                // Numbers and symbols only (`\(count)`, `\(value)%`) have nothing to translate.
                let words = literal.replacingOccurrences(
                    of: #"\\\((?:[^()]|\((?:[^()])*\))*\)"#, with: "", options: .regularExpression)
                guard words.contains(where: \.isLetter) else { continue }
                guard let matcher = matcher(for: literal) else { continue }
                let found = entries.contains { entry in
                    entry.hasPolish
                        && matcher.firstMatch(in: entry.key, range: NSRange(entry.key.startIndex..., in: entry.key))
                            != nil
                }
                if !found { missing.append("\(file.lastPathComponent): \(literal)") }
            }
        }
        #expect(missing.isEmpty, "literals without a Polish catalog key: \(missing)")
    }
}
