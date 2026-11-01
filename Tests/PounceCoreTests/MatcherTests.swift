import PounceKit
import Testing

@testable import PounceCore

private func match(_ query: String, _ title: String) -> MatchResult? {
    FuzzyMatcher.match(TextNormalizer.query(query), in: NormalizedText(title))
}

@Suite struct TextNormalizerTests {
    @Test func lowercasesAndFoldsDiacritics() {
        #expect(TextNormalizer.normalize("Zażółć Gęślą Jaźń") == "zazolc gesla jazn")
        #expect(TextNormalizer.normalize("Café Crème") == "cafe creme")
    }

    @Test func foldsLettersWithoutDecomposition() {
        #expect(TextNormalizer.normalize("ł") == "l")
        #expect(TextNormalizer.normalize("Łódź") == "lodz")
        #expect(TextNormalizer.normalize("Straße") == "strasse")
        #expect(TextNormalizer.normalize("Ærø") == "aero")
    }

    @Test func queryTrimsWhitespaceButKeepsRawText() {
        let query = TextNormalizer.query("  Łąka ")
        #expect(query.raw == "  Łąka ")
        #expect(query.normalized == "laka")
        #expect(TextNormalizer.query("   ").isEmpty)
    }

    @Test func expandedLettersMapBackToTheirOriginalCharacter() {
        let text = NormalizedText("Ærø")
        #expect(text.normalized == "aero")
        #expect(text.originalOffsets == [0, 0, 1, 2])
    }
}

@Suite struct FuzzyMatcherTests {
    @Test func acronymMatchesWordInitials() throws {
        let result = try #require(match("vsc", "Visual Studio Code"))
        #expect(result.tier == .wordStart)
        #expect(result.highlightRanges == [0..<1, 7..<8, 14..<15])
    }

    @Test func prefixOfALocalizedName() throws {
        let result = try #require(match("kalk", "Kalkulator"))
        #expect(result.tier == .prefix)
        #expect(result.highlightRanges == [0..<4])
    }

    @Test func polishLettersMatchTheirAsciiQuery() throws {
        let result = try #require(match("l", "ł"))
        #expect(result.tier == .exact)
        let reverse = try #require(match("łódź", "Lodz Maps"))
        #expect(reverse.tier == .prefix)
        let word = try #require(match("zolc", "Zażółć"))
        #expect(word.tier == .substring)
        #expect(word.highlightRanges == [2..<6])
    }

    @Test func exactMatchIgnoresCase() throws {
        let result = try #require(match("safari", "Safari"))
        #expect(result.tier == .exact)
        #expect(result.score == 1)
    }

    @Test func wordStartInTheMiddleOfATitle() throws {
        let result = try #require(match("studio", "Visual Studio Code"))
        #expect(result.tier == .wordStart)
        #expect(result.highlightRanges == [7..<13])
        let camel = try #require(match("time", "FaceTime"))
        #expect(camel.tier == .wordStart)
    }

    @Test func substringAndFuzzyTiers() throws {
        let substring = try #require(match("ari", "Safari"))
        #expect(substring.tier == .substring)
        #expect(substring.highlightRanges == [3..<6])

        let fuzzy = try #require(match("sfr", "Safari"))
        #expect(fuzzy.tier == .fuzzy)
        #expect(fuzzy.highlightRanges == [0..<1, 2..<3, 4..<5])
        #expect(fuzzy.score > 0 && fuzzy.score <= 1)
    }

    @Test func nonMatchesAndEmptyQueries() {
        #expect(match("xyz", "Safari") == nil)
        #expect(match("", "Safari") == nil)
        #expect(match("safari browser", "Safari") == nil)
    }

    @Test func fuzzyPrefersBoundariesAndConsecutiveRuns() throws {
        let boundary = try #require(match("gc", "Google Chrome"))
        #expect(boundary.tier == .wordStart)
        let boundaries = try #require(FuzzyMatcher.fuzzy(Array("abc".unicodeScalars), NormalizedText("xabcx a b c")))
        #expect(boundaries.1 == [6, 8, 10])
        let consecutive = try #require(FuzzyMatcher.fuzzy(Array("abc".unicodeScalars), NormalizedText("xaxbxc abcd")))
        #expect(consecutive.1 == [7, 8, 9])
    }

    @Test func tierOrderIsStableAcrossTitles() {
        let titles = ["Notes", "Notes Helper", "Sticky Notes", "Keynote Notes", "Nodes Explorer"]
        let query = TextNormalizer.query("notes")
        let tiers = titles.compactMap { title in
            FuzzyMatcher.match(query, in: NormalizedText(title)).map { (title, $0.tier) }
        }
        #expect(tiers.map(\.1) == [.exact, .prefix, .wordStart, .wordStart])
        #expect(MatchTier.allCases.sorted() == [.exact, .prefix, .wordStart, .substring, .fuzzy])
        let substring = match("otes", "Notes")
        #expect(substring?.tier == .substring)
        let fuzzy = match("nts", "Notes")
        #expect(fuzzy?.tier == .fuzzy)
    }
}
