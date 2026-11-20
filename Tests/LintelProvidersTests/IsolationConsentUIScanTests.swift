import Foundation
import Testing

/// CODE_REVIEW.md section 8: `isolationVerified: true` may only appear together with the provider-choice UI that
/// carries the fixed "data leaves this Mac" information. The UI is found by a stable marker, a localisation key.
///
/// Limits (what this cannot prove): it checks that a non-comment line of an app source uses the key and that the
/// String Catalog has `en` and `pl` values for it. It cannot prove the string is shown at the right place, that the
/// view is reachable, or that the measurement on the real CLI was made; a dead string would pass. The reviewer checks
/// those (CODE_REVIEW.md section 8).
@Suite struct IsolationConsentUIScanTests {
    /// The marker the provider-choice UI must use (A6 adds it; this PR adds no UI).
    static let marker = "providerChoice.dataLeavesComputer"

    private static var root: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Removes `//` comments (whole-line and trailing) and `/* */` blocks, so a marker in a comment does not count.
    static func withoutComments(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        var inString = false
        while index < text.endIndex {
            let rest = text[index...]
            if !inString, rest.hasPrefix("//") {
                while index < text.endIndex, text[index] != "\n" { index = text.index(after: index) }
                continue
            }
            if !inString, rest.hasPrefix("/*") {
                if let end = rest.range(of: "*/") { index = end.upperBound } else { index = text.endIndex }
                continue
            }
            let c = text[index]
            if c == "\\", inString, text.index(after: index) < text.endIndex {
                out.append(c)
                index = text.index(after: index)
                out.append(text[index])
                index = text.index(after: index)
                continue
            }
            if c == "\"" { inString.toggle() }
            out.append(c)
            index = text.index(after: index)
        }
        return out
    }

    static func descriptorIsVerified(_ source: String) -> Bool {
        withoutComments(source).range(of: #"isolationVerified:\s*true\b"#, options: .regularExpression) != nil
    }

    /// Empty when fine; else the reason.
    static func problems(descriptor: String, appSources: [String], catalog: String) -> [String] {
        guard descriptorIsVerified(descriptor) else { return [] }
        var found: [String] = []
        let quoted = "\"\(marker)\""
        if !appSources.contains(where: { withoutComments($0).contains(quoted) }) {
            found.append("isolationVerified is true but no app source uses \(quoted)")
        }
        if !catalogHasBothLanguages(catalog) { found.append("the String Catalog lacks en and pl for \(marker)") }
        return found
    }

    static func catalogHasBothLanguages(_ catalog: String) -> Bool {
        guard let data = catalog.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let strings = json["strings"] as? [String: Any],
            let entry = strings[marker] as? [String: Any],
            let locs = entry["localizations"] as? [String: Any]
        else { return false }
        func value(_ lang: String) -> String? {
            ((locs[lang] as? [String: Any])?["stringUnit"] as? [String: Any])?["value"] as? String
        }
        return ["en", "pl"].allSatisfy { !(value($0) ?? "").isEmpty }
    }

    private static func appSourceTexts() throws -> [String] {
        let dir = root.appending(path: "Sources", directoryHint: .isDirectory)
        let files = try #require(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
        return try files.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && !$0.path.contains("/Sources/LintelProviders/") }
            .map { try String(contentsOf: $0, encoding: .utf8) }
    }

    @Test func theRepositoryKeepsTheRule() throws {
        let descriptor = try String(
            contentsOf: Self.root.appending(path: "Sources/LintelProviders/ProviderDescriptor.swift"), encoding: .utf8)
        let catalog = try String(
            contentsOf: Self.root.appending(path: "Resources/Localizable.xcstrings"), encoding: .utf8)
        #expect(Self.problems(descriptor: descriptor, appSources: try Self.appSourceTexts(), catalog: catalog) == [])
    }

    @Test func theDescriptorTextIsReadAsUnverifiedToday() throws {
        let descriptor = try String(
            contentsOf: Self.root.appending(path: "Sources/LintelProviders/ProviderDescriptor.swift"), encoding: .utf8)
        #expect(!Self.descriptorIsVerified(descriptor))
    }

    private static let verified = "static let x = D(isolationVerified: true, environmentAllowlist: [])"
    private static let goodCatalog =
        #"{"strings":{"providerChoice.dataLeavesComputer":{"localizations":{"en":{"stringUnit":{"value":"a"}},"pl":{"stringUnit":{"value":"b"}}}}}}"#

    @Test func verifiedWithoutTheMarkerFails() {
        #expect(!Self.problems(descriptor: Self.verified, appSources: ["let a = 1"], catalog: Self.goodCatalog).isEmpty)
    }

    @Test func aMarkerInACommentDoesNotCount() {
        let commented = [
            "// Text(\"\(Self.marker)\")", "/* \"\(Self.marker)\" */", "let a = 1 // \"\(Self.marker)\"",
        ]
        for source in commented {
            #expect(!Self.problems(descriptor: Self.verified, appSources: [source], catalog: Self.goodCatalog).isEmpty)
        }
    }

    @Test func aMarkerInCodeWithBothLanguagesPasses() {
        let ui = "Text(\"\(Self.marker)\")"
        #expect(Self.problems(descriptor: Self.verified, appSources: [ui], catalog: Self.goodCatalog).isEmpty)
    }

    @Test func aMissingPolishStringFails() {
        let ui = "Text(\"\(Self.marker)\")"
        let enOnly =
            #"{"strings":{"providerChoice.dataLeavesComputer":{"localizations":{"en":{"stringUnit":{"value":"a"}}}}}}"#
        #expect(!Self.problems(descriptor: Self.verified, appSources: [ui], catalog: enOnly).isEmpty)
    }

    @Test func unverifiedNeedsNothing() {
        let unverified = "D(isolationVerified: false, environmentAllowlist: [])"
        #expect(Self.problems(descriptor: unverified, appSources: [], catalog: "{}").isEmpty)
    }
}
