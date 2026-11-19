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
        item.mustDrop.filter { !markers.contains(spoken($0)) }
    }

    /// Whether `text` still holds a word of the withdrawn version.
    static func keepsWithdrawn(_ text: String, _ item: Case) -> Bool {
        let words = Set(tokens(text))
        return withdrawnWords(item).contains { holds(words, $0) }
    }

    static func load() throws -> [Case] {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/autocorrect/cases", withExtension: "json"))
        return try JSONDecoder().decode([Case].self, from: Data(contentsOf: url))
    }

    /// Lower-cased words of a text, split on anything that is not a letter, digit or apostrophe.
    static func tokens(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }.map(String.init)
    }

    /// The forms a `must_keep` or `must_drop` entry accepts: "jedenastej|11" is the spoken word first, then the
    /// digits the cleanup prompt may write instead.
    static func forms(_ entry: String) -> [String] {
        entry.lowercased().split(separator: "|").map(String.init)
    }

    /// The spoken form of an entry, the one the raw and expected texts use.
    static func spoken(_ entry: String) -> String {
        forms(entry).first ?? entry.lowercased()
    }

    /// Whether a set of words holds any form of an entry.
    static func holds(_ words: Set<String>, _ entry: String) -> Bool {
        forms(entry).contains { words.contains($0) }
    }

    /// Whether `text` keeps every `mustKeep` word and drops every `mustDrop` word.
    static func satisfies(_ text: String, _ item: Case) -> Bool {
        let words = Set(tokens(text))
        return item.mustKeep.allSatisfy { holds(words, $0) }
            && item.mustDrop.allSatisfy { !holds(words, $0) }
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
                #expect(raw.contains(AutocorrectCorpus.spoken(word)), "\(item.id): \(word) is not in raw")
            }
        }
    }

    @Test func expectedKeepsAndDropsTheListedWords() throws {
        for item in try AutocorrectCorpus.load() {
            let words = Set(AutocorrectCorpus.tokens(item.expected))
            for word in item.mustKeep {
                #expect(words.contains(AutocorrectCorpus.spoken(word)), "\(item.id): expected lost \(word)")
            }
            for word in item.mustDrop {
                #expect(!AutocorrectCorpus.holds(words, word), "\(item.id): expected still has \(word)")
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

    /// Owner decision 7: the guard must let the corpus' `expected` texts through (a correctly removed retraction
    /// is not "too short"). Counts per category go to the PR body; a rejected `expected` fails the test.
    @Test func guardAcceptsEveryExpectedText() throws {
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
        #expect(rejected.isEmpty, "\(rejected)")
    }

    /// Attacks on every case: an empty answer, an unrelated text, a cut-off beginning, an addition, and the
    /// ADR 0005 failure with a known bad output must not be accepted as the cleaned text... except where the
    /// known bad output is a plausible cleaning the guard cannot judge (reported, never counted as a pass).
    @Test func guardRejectsEmptyForeignTruncatedAndExtendedOutputs() throws {
        for item in try AutocorrectCorpus.load() {
            #expect(FormatterGuard.check(input: item.raw, output: "") == .rejected(.empty), "\(item.id)")
            let foreign = FormatterGuard.check(input: item.raw, output: "Jutro rano będzie padał deszcz w całym kraju.")
            #expect(foreign != .accepted("Jutro rano będzie padał deszcz w całym kraju."), "\(item.id): foreign")
            let extended = item.expected + " Dodatkowo proszę o potwierdzenie rezerwacji sali i przesłanie notatki."
            #expect(
                FormatterGuard.check(input: item.raw, output: extended) != .accepted(extended), "\(item.id): extended")
            // Chunks under five words are bounded only by the +3 rule, so they are not cut here.
            if AutocorrectCorpus.withdrawing.contains(item.category), FormatterGuard.words(in: item.raw) >= 5 {
                let words = item.raw.split(separator: " ")
                let cut = words.prefix(words.count / 2).joined(separator: " ") + "."
                // A cut that happens to end on the input's last word ("... sofę albo jednak szarą sofę" ->
                // "kupimy czerwoną sofę") is the kept-withdrawn-version failure of ADR 0005. The guard cannot
                // tell which version stayed; the real-model report measures it.
                let sameEnd = AutocorrectCorpus.tokens(cut).last == AutocorrectCorpus.tokens(item.raw).last
                if !sameEnd {
                    #expect(FormatterGuard.check(input: item.raw, output: cut) != .accepted(cut), "\(item.id): cut")
                }
            }
        }
    }

    /// The negative cases are text that only looks like a retraction; the guard accepts them unchanged.
    @Test func guardAcceptsNegativesUnchangedAndRejectsDroppingThem() throws {
        for item in try AutocorrectCorpus.load() where item.category == "negative" {
            #expect(
                FormatterGuard.check(input: item.raw, output: item.expected) == .accepted(item.expected), "\(item.id)")
            let words = item.expected.split(separator: " ")
            let lost = words.prefix(max(1, words.count / 3)).joined(separator: " ") + "."
            #expect(FormatterGuard.check(input: item.raw, output: lost) != .accepted(lost), "\(item.id): lost")
        }
    }

    /// Cleans every case with the built-in model in `LINTEL_LLAMA_MODEL` and prints only counts per category
    /// (no text): cases that keep and drop the right words, cleaned outputs that still hold the withdrawn
    /// version (the ADR 0005 failure), cleaned outputs equal to a `known_bad` text (reported on its own, never counted as a pass) and chunks that fell back to the raw text (the guard rejected the answer). Off by default, like the other
    /// real-model tests. It loads its own copy of the model, so run it alone:
    /// `LINTEL_LLAMA_MODEL=<gguf> swift test --filter AutocorrectCorpusTests`.
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
        var knownBadHit: [String: Int] = [:]
        var lostFinal: [String: Int] = [:]
        var total: [String: Int] = [:]
        for item in try AutocorrectCorpus.load() {
            let key = "\(item.lang)/\(item.category)"
            total[key, default: 0] += 1
            let result = try await formatter.format(chunk: item.raw, previousContext: nil)
            if AutocorrectCorpus.satisfies(result.text, item) { passed[key, default: 0] += 1 }
            let resultTokens = AutocorrectCorpus.tokens(result.text)
            // The texts are synthetic; with the variable set, the failing ones are printed for prompt work.
            if ProcessInfo.processInfo.environment["LINTEL_CORPUS_VERBOSE"] != nil,
                !AutocorrectCorpus.satisfies(result.text, item)
            {
                var answer = ""
                if case .fellBack = result.outcome {
                    let messages = CleanupPrompt.messages(transcript: item.raw, context: nil)
                    answer = (try? await warm.generate(messages: messages, maxTokens: 128)) ?? "?"
                }
                print("[autocorrect-fail] \(item.id) \(result.outcome): \(result.text) || \(answer)")
            }
            if case .fellBack = result.outcome {
                fellBack[key, default: 0] += 1
            } else {
                // A raw fallback keeps both versions (the safe failure) and may equal a known bad text, so only
                // an answer the model gave and the guard accepted counts here.
                if (item.knownBad ?? []).contains(where: { AutocorrectCorpus.tokens($0) == resultTokens }) {
                    knownBadHit[key, default: 0] += 1
                }
                if AutocorrectCorpus.keepsWithdrawn(result.text, item) {
                    keptWithdrawn[key, default: 0] += 1
                    // The ADR 0010 acceptance rule: the withdrawn version kept AND the final one lost.
                    let words = Set(AutocorrectCorpus.tokens(result.text))
                    if !item.mustKeep.allSatisfy({ AutocorrectCorpus.holds(words, $0) }) {
                        lostFinal[key, default: 0] += 1
                    }
                }
            }
        }
        await warm.unload()
        for key in total.keys.sorted() {
            let counts = "\(passed[key, default: 0])/\(total[key] ?? 0)"
            let failures =
                "keptWithdrawn \(keptWithdrawn[key, default: 0]) fellBack \(fellBack[key, default: 0])"
                + " knownBad \(knownBadHit[key, default: 0]) lostFinal \(lostFinal[key, default: 0])"
            print("[autocorrect-model] v\(CleanupPrompt.version) \(key): \(counts) \(failures)")
        }
    }
}

/// The prompt's examples teach the shape of a retraction; they must not be corpus cases, or a corpus pass
/// would measure memory instead of behaviour. This fails when an example (input or output) or a quoted phrase
/// of the system prompt shares three consecutive words with a corpus text, or too many content words, once
/// the marker phrases and fillers are removed.
@Suite struct CleanupPromptCorpusSeparationTests {
    private static let phrases: [[String]] =
        (FormatterGuard.retractionMarkers + FormatterGuard.fillers + [["nie"], ["albo"], ["no"], ["or"]])
        .sorted { $0.count > $1.count }

    /// Words of a text without marker phrases and fillers.
    static func stripped(_ text: String) -> [String] {
        var words = AutocorrectCorpus.tokens(text)
        var index = 0
        while index < words.count {
            if let phrase = phrases.first(where: { phrase in
                index + phrase.count <= words.count && Array(words[index..<(index + phrase.count)]) == phrase
            }) {
                words.removeSubrange(index..<(index + phrase.count))
            } else {
                index += 1
            }
        }
        return words
    }

    static func runs(_ words: [String], length: Int) -> Set<[String]> {
        guard words.count >= length else { return [] }
        return Set((0...(words.count - length)).map { Array(words[$0..<($0 + length)]) })
    }

    /// Words of four letters or more: the vocabulary that makes two sentences about the same thing.
    static func content(_ words: [String]) -> Set<String> {
        Set(words.filter { $0.count >= 4 })
    }

    /// The reasons `text` is too close to a corpus text, empty when it is not.
    static func overlaps(_ text: String, corpus: [AutocorrectCorpus.Case]) -> [String] {
        let words = stripped(text)
        let mine = runs(words, length: 3)
        let vocabulary = content(words)
        var found: [String] = []
        for item in corpus {
            for other in [item.raw, item.expected] {
                let theirs = stripped(other)
                if !mine.isDisjoint(with: runs(theirs, length: 3)) { found.append("\(item.id) run") }
                let common = vocabulary.intersection(content(theirs))
                let union = vocabulary.union(content(theirs))
                if !union.isEmpty, Double(common.count) / Double(union.count) >= 0.3 {
                    found.append("\(item.id) jaccard")
                }
            }
        }
        return found
    }

    /// The quoted samples in the system prompt that are phrases, not marker lists.
    static func quotedSamples() -> [String] {
        let parts = CleanupPrompt.system.components(separatedBy: "\"")
        return stride(from: 1, to: parts.count, by: 2).map { parts[$0] }
    }

    @Test func examplesAreNotCorpusCases() throws {
        let corpus = try AutocorrectCorpus.load()
        for (index, example) in CleanupPrompt.examples.enumerated() {
            #expect(Self.overlaps(example.input, corpus: corpus).isEmpty, "example \(index) input")
            #expect(Self.overlaps(example.output, corpus: corpus).isEmpty, "example \(index) output")
        }
        for sample in Self.quotedSamples() {
            #expect(Self.overlaps(sample, corpus: corpus).isEmpty, "system prompt sample \(sample)")
        }
    }

    @Test func theCheckCatchesACopiedCase() throws {
        let corpus = try AutocorrectCorpus.load()
        let item = try #require(corpus.first)
        #expect(!Self.overlaps(item.raw, corpus: corpus).isEmpty)
        #expect(!Self.overlaps(item.expected, corpus: corpus).isEmpty)
        let paraphrase = item.expected.split(separator: " ").dropLast().joined(separator: " ")
        #expect(!Self.overlaps(paraphrase, corpus: corpus).isEmpty)
    }
}
