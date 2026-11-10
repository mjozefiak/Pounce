import Foundation
import Testing

/// QA D4 and round 10 F5: "7 układów · No workspace uses Strefy". Every user-visible literal of the plugin's sources
/// must have a catalog key with a real Polish translation. The scanner reads across line breaks (swift-format wraps
/// `Text(` onto its own line) and covers `Text`, `Button`, `Label`, `Toggle`, `String(localized:)`,
/// `LocalizedStringResource` and `LocalizedStringKey`; a key counts only when its `pl` value is non-empty, marked
/// translated and different from the English key (unless the string is the same in both languages on purpose).
@Suite(.timeLimit(.minutes(1))) struct LocalizationCoverageTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Strings that read the same in English and Polish (symbols and format-only text).
    private static let sameInBothLanguages: Set<String> = [
        "%@: %@", "%@", "%lld%%", "%lld pt", "Esc", "⌘S", "x", "y",
    ]

    struct Entry {
        var key: String
        /// Every Polish string unit of the key (a plural has several).
        var polish: [(state: String, value: String)]
    }

    // MARK: Scanner (pure, tested below)

    /// The first string literal of each localized call in `text`, `verbatim:` calls excluded.
    static func literals(in text: String) -> [String] {
        let pattern =
            #"(?:String\(\s*localized:\s*|\b(?:Text|Button|Label|Toggle|LocalizedStringResource|LocalizedStringKey|Picker|Stepper|LabeledContent|TextField|SecureField|Section|Menu|GroupBox|DisclosureGroup|Link|Slider|ProgressView|Gauge|field)\(\s*|\.(?:accessibilityLabel|accessibilityHint|accessibilityValue|help|navigationTitle)\(\s*)"((?:[^"\\]|\\.)*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// A pattern that the catalog key of a literal matches: each interpolation becomes a format specifier.
    static func matcher(for literal: String) -> NSRegularExpression? {
        var pattern = ""
        var rest = Substring(literal)
        // A literal percent sign is `%%` in the key of an interpolated string and `%` in a plain one.
        let percent = literal.contains("\\(") ? "%%" : "%"
        while let start = rest.range(of: "\\(") {
            // A literal percent sign is `%%` in a catalog key.
            pattern += NSRegularExpression.escapedPattern(
                for: String(rest[..<start.lowerBound]).replacingOccurrences(of: "%", with: percent))
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
        pattern += NSRegularExpression.escapedPattern(for: String(rest).replacingOccurrences(of: "%", with: percent))
        return try? NSRegularExpression(pattern: "^" + pattern + "$")
    }

    /// The literals of `text` that have no catalog key with a real Polish translation.
    static func missing(in text: String, entries: [Entry]) -> [String] {
        literals(in: text).filter { literal in
            // Numbers and symbols only (`\(count)`, `\(value)%`) have nothing to translate.
            let words = literal.replacingOccurrences(
                of: #"\\\((?:[^()]|\((?:[^()])*\))*\)"#, with: "", options: .regularExpression)
            guard words.contains(where: \.isLetter), let matcher = matcher(for: literal) else { return false }
            return !entries.contains { entry in
                matcher.firstMatch(in: entry.key, range: NSRange(entry.key.startIndex..., in: entry.key)) != nil
                    && isTranslated(entry)
            }
        }
    }

    static func isTranslated(_ entry: Entry) -> Bool {
        guard !entry.polish.isEmpty else { return false }
        return entry.polish.allSatisfy {
            $0.state == "translated" && !$0.value.trimmingCharacters(in: .whitespaces).isEmpty
                && ($0.value != entry.key || sameInBothLanguages.contains(entry.key))
        }
    }

    private func catalog() throws -> [Entry] {
        let data = try Data(contentsOf: Self.root.appending(path: "Resources/Localizable.xcstrings"))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(object["strings"] as? [String: Any])
        return strings.map { key, value in
            let localizations = (value as? [String: Any])?["localizations"] as? [String: Any]
            var units: [(String, String)] = []
            func collect(_ node: Any?) {
                guard let dictionary = node as? [String: Any] else { return }
                if let unit = dictionary["stringUnit"] as? [String: Any] {
                    units.append((unit["state"] as? String ?? "", unit["value"] as? String ?? ""))
                }
                for child in dictionary.values { collect(child) }
            }
            collect(localizations?["pl"])
            return Entry(key: key, polish: units)
        }
    }

    // MARK: The check

    @Test func everyLocalizedLiteralOfThePluginHasARealPolishTranslation() throws {
        let entries = try catalog()
        let sources = Self.root.appending(path: "Sources/WindowsPlugin")
        let files =
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(files.count > 20)
        var missing: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            missing += Self.missing(in: text, entries: entries).map { "\(file.lastPathComponent): \($0)" }
        }
        #expect(missing.isEmpty, "literals without a Polish translation: \(missing)")
    }

    /// Round-16 audit L-2: the Polish word for a workspace is "obszar roboczy" everywhere in the plugin ("przestrzeń
    /// robocza" crept into two new strings). No Polish value of a plugin key may use the rejected word.
    static let rejectedPolishStems = ["przestrze"]

    static func rejectedTermUses(in text: String, entries: [Entry]) -> [String] {
        var found: [String] = []
        for literal in literals(in: text) {
            guard let matcher = matcher(for: literal) else { continue }
            for entry in entries
            where matcher.firstMatch(in: entry.key, range: NSRange(entry.key.startIndex..., in: entry.key)) != nil {
                for unit in entry.polish
                where rejectedPolishStems.contains(where: { unit.value.lowercased().contains($0) }) {
                    found.append("\(entry.key) → \(unit.value)")
                }
            }
        }
        return found
    }

    @Test func noPolishValueOfAPluginKeyUsesTheRejectedWordForAWorkspace() throws {
        let entries = try catalog()
        let sources = Self.root.appending(path: "Sources/WindowsPlugin")
        let files =
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        var found: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            found += Self.rejectedTermUses(in: text, entries: entries)
        }
        #expect(found.isEmpty, "use \"obszar roboczy\": \(found)")
        // The check itself catches the rejected word.
        let sample = [Entry(key: "Workspaces", polish: [("translated", "Przestrzenie robocze")])]
        #expect(!Self.rejectedTermUses(in: "Text(\"Workspaces\")", entries: sample).isEmpty)
    }

    // MARK: Self-test: the scanner and the check catch what they claim to

    private let sample = [
        Entry(key: "Known", polish: [("translated", "Znane")]),
        Entry(key: "Untranslated", polish: [("new", "Untranslated")]),
        Entry(key: "Empty", polish: [("translated", "")]),
        Entry(key: "Echo", polish: [("translated", "Echo")]),
        Entry(key: "%@: %@", polish: [("translated", "%@: %@")]),
        Entry(key: "%lld things", polish: [("translated", "%lld rzeczy")]),
    ]

    @Test func theScannerSeesWrappedCallsAndEveryKindOfLiteral() {
        let text = """
            Text(
                "Wrapped",
                comment: "c")
            Button("Plain") {}
            Label("Labelled", systemImage: "x")
            let a = String(
                localized: "Resource key", comment: "c")
            let b = LocalizedStringResource("Another", comment: "c")
            let c = LocalizedStringKey("Key")
            Text(verbatim: "Not localized")
            Text(model.value)
            """
        #expect(
            Self.literals(in: text) == ["Wrapped", "Plain", "Labelled", "Resource key", "Another", "Key"])
    }

    /// Round 16 D6: "width" and "height" stayed English in the Polish editor because they went through a helper's
    /// `LocalizedStringResource` parameter, which the scanner did not look at. Every other call form that takes a
    /// localizable literal is scanned too.
    @Test func theScannerSeesHelpersPickersFieldsAndAccessibilityModifiers() {
        let text = """
            field("width", value: 1) {}
            Picker("Kind", selection: $x) {}
            Stepper("Count", value: $n)
            LabeledContent("Row") {}
            TextField("Prompt", text: $t)
            Section("Heading") {}
            Menu("Choices") {}
            DisclosureGroup("More") {}
            .accessibilityLabel("Spoken label")
            .accessibilityHint("Spoken hint")
            .help("Tooltip")
            .navigationTitle("Title")
            Text(verbatim: "Skipped")
            .accessibilityIdentifier("skipped.id")
            """
        #expect(
            Self.literals(in: text) == [
                "width", "Kind", "Count", "Row", "Prompt", "Heading", "Choices", "More", "Spoken label", "Spoken hint",
                "Tooltip", "Title",
            ])
    }

    @Test func aMissingUntranslatedEmptyOrEchoedKeyIsCaughtAndKnownOnesPass() {
        let text = """
            Text("Known")
            Text("Missing")
            Text("Untranslated")
            Text("Empty")
            Text("Echo")
            Text("\\(name): \\(used)")
            Text("\\(count) things")
            Text("\\(count)")
            """
        #expect(Self.missing(in: text, entries: sample) == ["Missing", "Untranslated", "Empty", "Echo"])
    }
}
