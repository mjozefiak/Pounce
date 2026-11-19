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
        /// Outputs that keep the withdrawn version (the ADR 0005 failure: "o dziesiątej" kept instead of
        /// "o jedenastej"). Each must fail the corpus check on a withdrawn word.
        let knownBad: [String]?

        enum CodingKeys: String, CodingKey {
            case id, lang, category, raw, expected
            case mustKeep = "must_keep"
            case mustDrop = "must_drop"
            case knownBad = "known_bad"
        }
    }

    static let categories: Set<String> = [
        "retraction", "rethink", "correction", "falsestart", "filler", "negative",
    ]

    /// Categories in which the speaker withdraws a version and says another one.
    static let withdrawing: Set<String> = ["retraction", "rethink", "correction"]

    /// The words that only mark a correction. A `must_drop` list made of these alone would pass an output that
    /// keeps the withdrawn version and drops just the marker.
    static let markers: Set<String> = [
        "nie", "czekaj", "jednak", "znaczy", "przepraszam", "pomyłka", "właściwie",
        "no", "wait", "actually", "mean", "sorry",
    ]

    /// The `must_drop` words that belong to the withdrawn version, not to the marker.
    static func withdrawnWords(_ item: Case) -> [String] {
        item.mustDrop.filter { !markers.contains($0.lowercased()) }
    }

    /// Whether `text` still holds a word of the withdrawn version.
    static func keepsWithdrawn(_ text: String, _ item: Case) -> Bool {
        let words = Set(tokens(text))
        return withdrawnWords(item).contains { words.contains($0.lowercased()) }
    }

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

    @Test func everyWithdrawalNamesTheWithdrawnValue() throws {
        for item in try AutocorrectCorpus.load() where AutocorrectCorpus.withdrawing.contains(item.category) {
            #expect(!AutocorrectCorpus.withdrawnWords(item).isEmpty, "\(item.id): must_drop holds only markers")
        }
    }

    /// ADR 0005: the default model kept the withdrawn time ("o dziesiątej") and dropped the correction. The
    /// corpus check must catch that output through `must_drop`, not only through a missing `must_keep` word.
    @Test func knownBadOutputsKeepingTheWithdrawnVersionFail() throws {
        let cases = try AutocorrectCorpus.load()
        let withBad = cases.filter { !($0.knownBad ?? []).isEmpty }
        #expect(withBad.filter { $0.lang == "pl" }.count >= 2)
        #expect(withBad.filter { $0.lang == "en" }.count >= 2)
        #expect(withBad.contains { $0.id == "pl-cor-1" })
        for item in withBad {
            #expect(AutocorrectCorpus.withdrawing.contains(item.category), "\(item.id)")
            for output in item.knownBad ?? [] {
                #expect(AutocorrectCorpus.keepsWithdrawn(output, item), "\(item.id): a known bad output passes")
                #expect(!AutocorrectCorpus.satisfies(output, item), "\(item.id): a known bad output passes")
            }
            #expect(!AutocorrectCorpus.keepsWithdrawn(item.expected, item), "\(item.id)")
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

    /// Cleans every case with the built-in model in `LINTEL_LLAMA_MODEL` and prints only counts per category
    /// (no text): cases that keep and drop the right words, cleaned outputs that still hold the withdrawn
    /// version (the ADR 0005 failure) and chunks that fell back to the raw text. Off by default, like the other
    /// real-model tests.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["LINTEL_LLAMA_MODEL"] != nil))
    func realModelPassCountsPerCategory() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["LINTEL_LLAMA_MODEL"])
        let warm = KeepWarmRuntime(
            runtime: LlamaRuntime(), modelURL: URL(fileURLWithPath: path), keepWarm: { .seconds(300) })
        let formatter = BuiltInFormatter(runtime: warm)
        await formatter.prepare()
        var passed: [String: Int] = [:]
        var keptWithdrawn: [String: Int] = [:]
        var fellBack: [String: Int] = [:]
        var total: [String: Int] = [:]
        for item in try AutocorrectCorpus.load() {
            let key = "\(item.lang)/\(item.category)"
            total[key, default: 0] += 1
            let result = try await formatter.format(chunk: item.raw, previousContext: nil)
            if AutocorrectCorpus.satisfies(result.text, item) { passed[key, default: 0] += 1 }
            if case .fellBack = result.outcome {
                fellBack[key, default: 0] += 1
            } else if AutocorrectCorpus.keepsWithdrawn(result.text, item) {
                keptWithdrawn[key, default: 0] += 1
            }
        }
        await warm.unload()
        for key in total.keys.sorted() {
            let counts = "\(passed[key, default: 0])/\(total[key] ?? 0)"
            let failures = "keptWithdrawn \(keptWithdrawn[key, default: 0]) fellBack \(fellBack[key, default: 0])"
            print("[autocorrect-model] \(key): \(counts) \(failures)")
        }
    }
}
