import Foundation
import Testing

/// The format of the fixed set of reference phrases (ADR 0010, story DICT-0.3). The resolvers of DICT-3.1 and
/// DICT-3.4 are judged against this file, so a phrase without a class or a thin `none` class must fail here.
struct ReferencePhrasesFormatTests {
    struct Document: Decodable {
        var version: Int
        var clipboardPhrases: [String]
        var files: [String]
        var phrases: [Phrase]
    }

    struct Phrase: Decodable {
        var id: String?
        var language: String?
        var segments: [String]?
        var expected: String?
        var file: String?
        var kind: String?
    }

    static let classes: Set<String> = ["clipboard", "file", "none"]
    static let languages: Set<String> = ["pl", "en"]
    static let noneKinds: Set<String> = ["prose", "unresolved"]

    /// A transcript reads "Wklej schowek."; the phrase list holds "wklej schowek".
    static func normalized(_ segment: String) -> String {
        segment.lowercased().trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
    }

    static func load() throws -> Document {
        let url = try #require(
            Bundle.module.url(forResource: "Fixtures/context/reference-phrases", withExtension: "json"))
        return try JSONDecoder().decode(Document.self, from: Data(contentsOf: url))
    }

    /// Every way the file breaks the format; empty when it is valid.
    static func problems(in document: Document) -> [String] {
        var problems: [String] = []
        let phrases = document.phrases
        if phrases.count < 60 { problems.append("fewer than 60 phrases: \(phrases.count)") }

        let ids = phrases.compactMap(\.id)
        if ids.count != phrases.count { problems.append("a phrase has no id") }
        if Set(ids).count != ids.count { problems.append("ids repeat") }

        let clipboardPhrases = Set(document.clipboardPhrases)
        if clipboardPhrases.isEmpty { problems.append("no clipboard phrases") }
        let files = Set(document.files)

        for phrase in phrases {
            let name = phrase.id ?? "?"
            guard let expected = phrase.expected else {
                problems.append("\(name): no class")
                continue
            }
            if !classes.contains(expected) { problems.append("\(name): unknown class \(expected)") }
            if !languages.contains(phrase.language ?? "") { problems.append("\(name): language is not pl or en") }

            let segments = phrase.segments ?? []
            let isBlank = { (segment: String) in segment.trimmingCharacters(in: .whitespaces).isEmpty }
            if segments.isEmpty || segments.contains(where: isBlank) {
                problems.append("\(name): empty segments")
            }

            // The rule "the phrase is a whole segment" must be readable from the file itself.
            let hasWholePhrase = segments.contains { clipboardPhrases.contains(normalized($0)) }
            if expected == "clipboard", !hasWholePhrase {
                problems.append("\(name): no segment is a clipboard phrase")
            }
            if expected != "clipboard", hasWholePhrase {
                problems.append("\(name): a clipboard phrase as a whole segment outside the clipboard class")
            }

            if expected == "file" {
                if !files.contains(phrase.file ?? "") { problems.append("\(name): file is not in the tree") }
            } else if phrase.file != nil {
                problems.append("\(name): a file outside the file class")
            }
            if expected == "none", !noneKinds.contains(phrase.kind ?? "") {
                problems.append("\(name): a none phrase is neither prose nor unresolved")
            }
        }

        for expected in classes.sorted() {
            let inClass = phrases.filter { $0.expected == expected }
            if expected == "none" {
                // Unresolved references do not count: the class must hold enough ordinary prose.
                let prose = inClass.filter { $0.kind == "prose" }.count
                if prose < 20 { problems.append("class none has \(prose) plain phrases, needs 20") }
            } else if inClass.count < 15 {
                problems.append("class \(expected) has \(inClass.count) phrases, needs 15")
            }
            for language in languages.sorted() where !inClass.contains(where: { $0.language == language }) {
                problems.append("class \(expected) has no \(language) phrase")
            }
        }
        return problems
    }

    @Test func theFileIsValid() throws {
        let document = try Self.load()
        #expect(document.version == 1)
        #expect(Self.problems(in: document) == [])
    }

    @Test func aPhraseWithoutAClassFails() throws {
        var document = try Self.load()
        let index = try #require(document.phrases.firstIndex { $0.expected == "clipboard" })
        let id = try #require(document.phrases[index].id)
        document.phrases[index].expected = nil
        #expect(Self.problems(in: document).contains("\(id): no class"))
    }

    @Test func fewerThanTwentyPlainPhrasesFail() throws {
        var document = try Self.load()
        var kept = 0
        document.phrases.removeAll { phrase in
            guard phrase.expected == "none", phrase.kind == "prose" else { return false }
            kept += 1
            return kept > 19
        }
        #expect(Self.problems(in: document).contains("class none has 19 plain phrases, needs 20"))
    }
}
