import Foundation
import Testing

private let repositoryRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// The same checks as the "Check the page" step of `.github/workflows/pages.yml`, so a missing Polish string
/// fails `swift test` before CI: every `data-i18n` key has a Polish string, ids are unique and anchors resolve.
@Suite struct LandingPageTests {
    private func page() throws -> String {
        try String(contentsOf: repositoryRoot.appending(path: "docs/index.html"), encoding: .utf8)
    }

    private func matches(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) throws
        -> [[String]]
    {
        let regex = try NSRegularExpression(pattern: pattern, options: options)
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }

    @Test func everyTranslatedElementHasAPolishString() throws {
        let page = try page()
        let keys = try matches(#"data-i18n="([^"]+)""#, in: page).map { $0[1] }
        #expect(keys.count > 40)
        let table = try #require(
            try matches(#"var PL = \{(.*?)\n  \};"#, in: page, options: [.dotMatchesLineSeparators]).first)
        let translated = Set(try matches(#"^\s*"([^"]+)":"#, in: table[1], options: [.anchorsMatchLines]).map { $0[1] })
        let missing = Set(keys).subtracting(translated).sorted()
        #expect(missing.isEmpty, "Missing Polish strings: \(missing.joined(separator: ", "))")
    }

    @Test func idsAreUniqueAndAnchorsResolve() throws {
        let page = try page()
        let ids = try matches(#"\sid="([^"]+)""#, in: page).map { $0[1] }
        #expect(ids.count == Set(ids).count)
        for anchor in try matches(##"<a\s[^>]*href="#([^"]+)""##, in: page).map({ $0[1] }) {
            #expect(ids.contains(anchor), "Broken anchor #\(anchor)")
        }
    }

    @Test func theMeetingsCopySaysWhereTheAudioGoesInBothLanguages() throws {
        let page = try page()
        // The privacy promises of the spec: system audio, other people's voices, encrypted until the transcript
        // is ready, nothing leaves the Mac but the model download.
        #expect(page.contains("System audio recording"))
        #expect(page.contains("other people are processed too, but only on your Mac"))
        #expect(page.contains("stored encrypted until the transcript is ready, then deleted"))
        #expect(page.contains("Nothing leaves your Mac except the model download"))
        #expect(page.contains("Audio, dictated text and meeting transcripts never leave your Mac"))
        #expect(page.contains("Nagrywanie dźwięku systemu"))
        #expect(page.contains("tylko na Twoim Macu"))
        // Notes are Phase 2: the page promises a transcript with speakers only.
        #expect(!page.localizedCaseInsensitiveContains("meeting notes"))
        #expect(!page.localizedCaseInsensitiveContains("notatki ze spotka"))
    }
}
