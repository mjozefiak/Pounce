import Foundation
import Testing

@testable import DictationPlugin
@testable import LintelSpeech

/// A synthetic, invented corpus of dictated self-corrections (owner decision 7, preparation for CleanupPrompt
/// v2). Nothing in it comes from a real dictation or meeting. `expected` removes only the explicitly withdrawn
/// part, never summarises and never adds content; the negative cases use "albo", "nie" and "czekaj" (or "or",
/// "no", "wait") as ordinary content, so nothing may be removed from them.
enum AutocorrectCorpus {
    struct Case: Decodable {
        let id: String
        let lang: String
        let category: String
        let raw: String
        let expected: String
        let mustKeep: [String]
        let mustDrop: [String]

        enum CodingKeys: String, CodingKey {
            case id, lang, category, raw, expected
            case mustKeep = "must_keep"
            case mustDrop = "must_drop"
        }
    }

    static let categories: Set<String> = [
        "retraction", "rethink", "correction", "falsestart", "filler", "negative",
    ]

    static func load() throws -> [Case] {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/autocorrect/cases", withExtension: "json"))
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    /// Lower-cased words of a text, split on anything that is not a letter, digit or apostrophe.
    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "'" || $0 == "’") }.map(String.init)
    }

    /// Whether `text` keeps every `mustKeep` word and drops every `mustDrop` word.
    static func satisfies(_ text: String, _ item: Case) -> Bool {
        let words = Set(tokens(text))
        return item.mustKeep.allSatisfy { words.contains($0.lowercased()) }
            && item.mustDrop.allSatisfy { !words.contains($0.lowercased()) }
    }
}

@Suite struct AutocorrectCorpusTests {
    @Test func fixtureIsWellFormedAndUnique() throws {
        let cases = try AutocorrectCorpus.load()
        #expect(Set(cases.map(\.id)).count == cases.count)
        #expect(Set(cases.map(\.raw)).count == cases.count)
        for item in cases {
            #expect(!item.raw.isEmpty && !item.expected.isEmpty, "\(item.id)")
            #expect(["pl", "en"].contains(item.lang), "\(item.id)")
            #expect(AutocorrectCorpus.categories.contains(item.category), "\(item.id)")
            #expect(!item.mustKeep.isEmpty, "\(item.id)")
            #expect(item.id.hasPrefix(item.lang + "-"), "\(item.id)")
        }
    }

    @Test func eachMustKeepWordIsInTheRawText() throws {
        for item in try AutocorrectCorpus.load() {
            let raw = Set(AutocorrectCorpus.tokens(item.raw))
            for word in item.mustKeep + item.mustDrop {
                #expect(raw.contains(word.lowercased()), "\(item.id): \(word) is not in raw")
            }
        }
    }

    @Test func expectedKeepsAndDropsTheListedWords() throws {
        for item in try AutocorrectCorpus.load() {
            let words = Set(AutocorrectCorpus.tokens(item.expected))
            for word in item.mustKeep {
                #expect(words.contains(word.lowercased()), "\(item.id): expected lost \(word)")
            }
            for word in item.mustDrop {
                #expect(!words.contains(word.lowercased()), "\(item.id): expected still has \(word)")
            }
        }
    }

    @Test func expectedNeverAddsWordsAndNegativesLoseNone() throws {
        for item in try AutocorrectCorpus.load() {
            let raw = Set(AutocorrectCorpus.tokens(item.raw))
            let added = Set(AutocorrectCorpus.tokens(item.expected)).subtracting(raw)
            #expect(added.isEmpty, "\(item.id): expected adds \(added.sorted())")
            if item.category == "negative" {
                #expect(item.mustDrop.isEmpty, "\(item.id)")
                #expect(
                    AutocorrectCorpus.tokens(item.expected) == AutocorrectCorpus.tokens(item.raw),
                    "\(item.id): a negative case must keep every word")
            }
        }
    }

    @Test func coversEveryCategoryAndBothLanguages() throws {
        let cases = try AutocorrectCorpus.load()
        #expect(cases.filter { $0.lang == "pl" }.count >= 40)
        #expect(cases.filter { $0.lang == "en" }.count >= 20)
        for category in AutocorrectCorpus.categories {
            for lang in ["pl", "en"] {
                let count = cases.filter { $0.category == category && $0.lang == lang }.count
                #expect(count >= 3, "\(lang) \(category): \(count)")
            }
        }
    }

    /// Data for the next step (CleanupPrompt v2 and the guard): how many `expected` texts the current guard
    /// would turn back into the raw text. No blocking assertion; the numbers go to the PR body.
    @Test func reportsHowTheCurrentGuardTreatsExpected() throws {
        var rejected: [String: [String]] = [:]
        var total: [String: Int] = [:]
        for item in try AutocorrectCorpus.load() {
            total[item.category, default: 0] += 1
            if case .rejected(let reason) = FormatterGuard.check(input: item.raw, output: item.expected) {
                rejected[item.category, default: []].append("\(item.id):\(reason)")
            }
        }
        let all = rejected.values.reduce(0) { $0 + $1.count }
        print("[autocorrect-guard] rejected \(all) of \(total.values.reduce(0, +))")
        for category in total.keys.sorted() {
            let list = rejected[category, default: []]
            print("[autocorrect-guard] \(category): \(list.count)/\(total[category] ?? 0) \(list.sorted())")
        }
    }

    /// Cleans every case with the built-in model in `LINTEL_LLAMA_MODEL` and prints only how many cases per
    /// category keep and drop the right words (no text). Off by default, like the other real-model tests.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LINTEL_LLAMA_MODEL"] != nil))
    func realModelPassCountsPerCategory() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LINTEL_LLAMA_MODEL"])
        let warm = KeepWarmRuntime(
            runtime: LlamaRuntime(), modelURL: URL(fileURLWithPath: path), keepWarm: { .seconds(300) })
        let formatter = BuiltInFormatter(runtime: warm)
        await formatter.prepare()
        var passed: [String: Int] = [:]
        var total: [String: Int] = [:]
        for item in try AutocorrectCorpus.load() {
            let key = "\(item.lang)/\(item.category)"
            total[key, default: 0] += 1
            let result = try await formatter.format(chunk: item.raw, previousContext: nil)
            if AutocorrectCorpus.satisfies(result.text, item) { passed[key, default: 0] += 1 }
        }
        await warm.unload()
        for key in total.keys.sorted() {
            print("[autocorrect-model] \(key): \(passed[key, default: 0])/\(total[key] ?? 0)")
        }
    }
}
