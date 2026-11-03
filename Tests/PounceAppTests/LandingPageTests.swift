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

    /// The English text of an element (`data-i18n="key"`) and its Polish string.
    private func texts(_ key: String, in page: String) throws -> (en: String, pl: String) {
        let element = try #require(
            try matches("data-i18n=\"\(key)\">([^<]*)<", in: page).first, "No element for \(key)")
        let polish = try #require(
            try matches("\"\(key)\": \"((?:[^\"\\\\]|\\\\.)*)\"", in: page).first, "No Polish string for \(key)")
        return (element[1], polish[1])
    }

    @Test func theAudioClaimIsTruthfulInBothLanguages() throws {
        let page = try page()
        let (en, pl) = try texts("a7", in: page)
        // Other people's voices are processed, only on this Mac, and nothing leaves it but the model download.
        #expect(en.contains("other people are processed too, but only on your Mac"))
        #expect(en.contains("Nothing leaves your Mac except the model download"))
        // The audio is encrypted and deleted once the transcript is ready; an interrupted meeting keeps it for
        // up to 7 days so it can be finished, then it is deleted too.
        #expect(en.contains("stored encrypted until the transcript is ready, then deleted"))
        #expect(en.contains("If a meeting is interrupted, its audio is kept for up to 7 days so you can finish it"))
        #expect(en.contains("7 days so you can finish it, then deleted"))
        #expect(pl.contains("zaszyfrowany do czasu gotowego transkryptu, potem kasowany"))
        #expect(pl.contains("Jeśli spotkanie zostanie przerwane, jego dźwięk jest zachowany do 7 dni"))
        #expect(pl.contains("dokończyć, a potem kasowany"))
        let (_, general) = try texts("a4", in: page)
        #expect(general.contains("dyktowania albo spotkań"))
        #expect(page.contains("System audio recording"))
        #expect(page.contains("Nagrywanie dźwięku systemu"))
        // No claim that audio is never kept: that is true of dictation only.
        let meetingCopy = try texts("f5.d", in: page)
        #expect(!meetingCopy.en.localizedCaseInsensitiveContains("never saved"))
        // Notes (Phase 2) are local, optional and checked against the recording; the model download is the only network use.
        #expect(meetingCopy.en.contains("also runs on your Mac"))
        #expect(meetingCopy.en.contains("checked against the recording"))
        #expect(meetingCopy.pl.contains("też działa na Twoim Macu"))
        #expect(meetingCopy.pl.contains("sprawdzany z nagraniem"))
        #expect(general.contains("językowy"))
        #expect(general.contains("notatki ze spotkań nigdy nie opuszczają Maca"))
        let (generalEn, _) = try texts("a4", in: page)
        #expect(generalEn.contains("meeting transcripts and notes never leave your Mac"))
    }

    @Test func theFeatureCountMatchesTheCards() throws {
        let page = try page()
        let cards = try matches(#"<li class="card">"#, in: page).count
        #expect(cards == 4)
        let words = [2: "Two", 3: "Three", 4: "Four", 5: "Five"]
        let polishWords = [2: "Dwie", 3: "Trzy", 4: "Cztery", 5: "Pięć"]
        let heading = try texts("feat.t", in: page)
        #expect(heading.en.hasPrefix(words[cards] ?? "?"))
        #expect(heading.pl.hasPrefix(polishWords[cards] ?? "?"))
        let lead = try texts("hero.lead", in: page)
        #expect(lead.en.contains("\(words[cards]?.lowercased() ?? "?") things"))
        #expect(!lead.en.contains("three things"))
        #expect(lead.pl.contains("czterema funkcjami"))
    }
}
