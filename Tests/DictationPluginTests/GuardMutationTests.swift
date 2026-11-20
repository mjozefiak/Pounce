import Foundation
import Testing

@testable import DictationPlugin

/// A property test over the synthetic corpus: for every withdrawing case, every mutation of the correct result
/// that changes the final version is rejected. The mutations are built here from the raw and expected texts and
/// a marker list of the test's own, not from anything inside `FormatterGuard`, so the test does not move with
/// the code under test.
///
/// A mutation is: a word after the marker swapped for another word of the input or for an invented word; the
/// marker dropped with both versions kept (with or without the word that joined them); the marker moved one
/// word; a number changed. A rejection of a correct, unmutated result is a false alarm (fail-safe: the raw
/// text is pasted); the test counts them and lists the ids.
@Suite struct GuardMutationTests {
    private static let markers: [[String]] = [
        ["czekaj"], ["jednak"], ["właściwie"], ["pomyłka"], ["przepraszam"], ["to", "znaczy"],
        ["wait"], ["actually"], ["sorry"], ["scratch", "that"], ["i", "mean"],
    ]
    private static let invented = ["zebra", "kwadrans", "Tomasza", "lemoniada"]
    private static let connectors: Set<String> = ["nie", "albo", "a", "lub", "or", "no", "and", "i"]

    private static func tokens(_ text: String) -> [String] { AutocorrectCorpus.tokens(text) }

    /// The first marker with a word after it: where it starts and ends in the tokens.
    private static func firstMarker(in tokens: [String]) -> (start: Int, end: Int)? {
        for index in tokens.indices {
            for marker in markers where index + marker.count < tokens.count {
                if Array(tokens[index..<(index + marker.count)]) == marker { return (index, index + marker.count) }
            }
        }
        return nil
    }

    private func accepted(_ input: String, _ output: String) -> Bool {
        if case .accepted = FormatterGuard.check(input: input, output: output) { return true }
        return false
    }

    private static func isWord(_ text: String, equalTo others: [String]) -> Bool {
        others.contains { $0 == text }
    }

    /// The mutants of one case: (name, output).
    private static func mutants(of item: AutocorrectCorpus.Case) -> [(String, String)] {
        let raw = tokens(item.raw)
        guard let marker = firstMarker(in: raw) else { return [] }
        let tail = Set(raw[marker.end...])
        let words = item.expected.split(separator: " ").map(String.init)
        var found: [(String, String)] = []

        // 1. A word of the final version swapped for another input word or an invented one.
        let others = Set(raw).subtracting(markers.flatMap { $0 })
        for (index, word) in words.enumerated() {
            let bare = tokens(word).first ?? ""
            guard tail.contains(bare) else { continue }
            let trailing = String(word.reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
            for other in others.sorted() + invented where other.lowercased() != bare {
                var changed = words
                changed[index] = other + trailing
                found.append(("swap \(bare) -> \(other)", changed.joined(separator: " ")))
            }
        }

        // 2. The marker dropped, both versions kept; with the joining word dropped too.
        let rawWords = item.raw.split(separator: " ").map(String.init)
        let markerRange = marker.start..<marker.end
        var without = rawWords
        without.removeSubrange(markerRange)
        found.append(("marker dropped", without.joined(separator: " ")))
        if marker.start > 0, connectors.contains(raw[marker.start - 1]) {
            var withoutJoin = rawWords
            withoutJoin.removeSubrange((marker.start - 1)..<marker.end)
            found.append(("marker and joining word dropped", withoutJoin.joined(separator: " ")))
        }

        // 3. The marker moved one word to the left or to the right.
        if marker.start > 0 {
            var moved = rawWords
            let phrase = Array(moved[markerRange])
            moved.removeSubrange(markerRange)
            moved.insert(contentsOf: phrase, at: marker.start - 1)
            found.append(("marker moved left", moved.joined(separator: " ")))
        }
        if marker.end < rawWords.count {
            var moved = rawWords
            let phrase = Array(moved[markerRange])
            moved.removeSubrange(markerRange)
            moved.insert(contentsOf: phrase, at: marker.start + 1)
            found.append(("marker moved right", moved.joined(separator: " ")))
        }

        // 4. A number changed: digits by one, a number word for another number word.
        let numberWords = [
            "dwa": "trzy", "dwie": "trzy", "trzy": "cztery", "cztery": "pięć", "pięć": "sześć", "sześć": "siedem",
            "two": "three", "three": "four", "four": "five", "five": "six", "six": "seven", "seven": "eight",
            "ten": "eleven", "eleven": "twelve", "twelve": "thirteen", "fifty": "sixty", "sixty": "seventy",
            "dziesiątej": "jedenastej", "jedenastej": "dwunastej", "piętnastej": "szesnastej",
        ]
        for (index, word) in words.enumerated() {
            let bare = word.lowercased().trimmingCharacters(in: .punctuationCharacters)
            var changed = words
            if let value = Int(bare) {
                changed[index] = word.replacingOccurrences(of: bare, with: String(value + 1))
            } else if let other = numberWords[bare] {
                changed[index] = other
            } else {
                continue
            }
            found.append(("number \(bare)", changed.joined(separator: " ")))
        }
        return found
    }

    @Test func everyMutationOfACorrectResultIsRejected() throws {
        var mutations = 0
        var cases = 0
        for item in try AutocorrectCorpus.load() where AutocorrectCorpus.withdrawing.contains(item.category) {
            let expected = Self.tokens(item.expected)
            for (name, output) in Self.mutants(of: item) {
                // A mutation that happens to write the same words as the correct result is no mutation.
                guard Self.tokens(output) != expected, Self.tokens(output) != Self.tokens(item.raw) else { continue }
                mutations += 1
                #expect(!accepted(item.raw, output), "\(item.id): \(name): \(output)")
            }
            cases += 1
        }
        print("[guard-mutations] \(cases) withdrawing cases, \(mutations) mutations, none accepted")
        #expect(cases == 38 && mutations > 1000)
    }

    @Test func theUnchangedInputWithItsMarkerKeptIsAccepted() throws {
        for item in try AutocorrectCorpus.load() {
            #expect(accepted(item.raw, item.raw), "\(item.id)")
            #expect(accepted(item.raw, item.raw.prefix(1).uppercased() + item.raw.dropFirst() + "."), "\(item.id)")
        }
    }

    /// The correct results the rule turns into the raw text (fail-safe false alarms): the replacement is another
    /// word of the same slot (the retracted span starts on a word that is not parallel to it).
    @Test func theFalseAlarmsOnTheCorpusAreTheListedOnes() throws {
        var rejected: [String] = []
        for item in try AutocorrectCorpus.load() where !accepted(item.raw, item.expected) { rejected.append(item.id) }
        print("[guard-false-alarms] \(rejected.count) of 79 expected texts: \(rejected.sorted())")
        #expect(
            rejected.sorted() == ["en-cor-4", "en-rth-1", "en-rth-3", "pl-cor-4", "pl-fil-7", "pl-rth-5"])
    }
}
